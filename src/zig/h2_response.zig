// HTTP/1.1 → HTTP/2 response transcoder (v1.11).
//
// saltare's Python dispatcher emits HTTP/1.1-shaped response bytes: a status
// line, header lines, and a body framed either with `Content-Length` or
// `Transfer-Encoding: chunked`. That is correct for the HTTP/1.1 wire but
// meaningless over HTTP/2, where a response is a HEADERS frame (HPACK-encoded,
// `:status` pseudo-header first) followed by DATA frames, terminated by the
// END_STREAM flag — chunked encoding is explicitly forbidden (RFC 7540 §8.1.2.2).
//
// Rather than teach the (large, well-tested) dispatcher a second wire format,
// this transcodes the bytes it already produces. The Python machinery —
// streaming, gzip, sendfile, content negotiation — stays untouched; only the
// final framing changes. Bytes are fed incrementally (the response arrives
// across several dispatcher ticks), so this is a resumable state machine.
//
// What it does:
//   * Parses the status line → `:status` pseudo-header (must be first in HPACK).
//   * Lowercases header names (HPACK/H2 require lowercase; uppercase is a
//     PROTOCOL_ERROR at the peer) and drops hop-by-hop headers that are
//     illegal in HTTP/2 (connection, keep-alive, transfer-encoding, upgrade,
//     proxy-connection) per RFC 7540 §8.1.2.2.
//   * De-frames chunked bodies back into a plain byte stream.
//   * Splits the body into DATA frames no larger than the peer's
//     SETTINGS_MAX_FRAME_SIZE.
//   * Places END_STREAM on the final frame: on HEADERS for an empty body,
//     otherwise on the last DATA frame (flushed by `finish`).

const std = @import("std");
const h2 = @import("h2.zig");
const h2_encoder = @import("h2_encoder.zig");

pub const Error = error{ OutOfMemory, MalformedResponse };

const Phase = enum { status_line, headers, body_length, body_chunked, done };

// Sub-state while de-framing a chunked body.
const ChunkState = enum { size_line, data, data_crlf, trailer };

pub const Transcoder = struct {
    allocator: std.mem.Allocator,
    stream_id: u31,
    max_frame_size: usize,

    phase: Phase = .status_line,
    // Accumulates status-line + header bytes until the terminating CRLFCRLF.
    head_buf: std.ArrayList(u8) = .empty,
    // Decoded response headers (owned copies; names lowercased), `:status` first.
    resp_headers: std.ArrayList(h2_encoder.Header) = .empty,
    status: []u8 = &.{},
    headers_emitted: bool = false,
    end_stream_sent: bool = false,

    // Body framing.
    content_length: ?usize = null, // null until parsed; set for Content-Length bodies
    length_remaining: usize = 0,
    no_body: bool = false, // status implies empty body (1xx/204/304) or CL 0

    // Chunked de-framing state.
    chunk_state: ChunkState = .size_line,
    chunk_remaining: usize = 0,
    line_buf: std.ArrayList(u8) = .empty,

    // Body bytes decoded but not yet framed; held so we can place END_STREAM
    // on the final DATA frame rather than emitting a trailing empty one.
    body_pending: std.ArrayList(u8) = .empty,

    pub fn init(allocator: std.mem.Allocator, stream_id: u31, max_frame_size: usize) Transcoder {
        return .{
            .allocator = allocator,
            .stream_id = stream_id,
            // Defend against a degenerate advertised size; HTTP/2 floors it at 2^14.
            .max_frame_size = if (max_frame_size < 16384) 16384 else max_frame_size,
        };
    }

    pub fn deinit(self: *Transcoder) void {
        self.head_buf.deinit(self.allocator);
        for (self.resp_headers.items) |h| {
            self.allocator.free(@constCast(h.name));
            self.allocator.free(@constCast(h.value));
        }
        self.resp_headers.deinit(self.allocator);
        if (self.status.len > 0) self.allocator.free(self.status);
        self.line_buf.deinit(self.allocator);
        self.body_pending.deinit(self.allocator);
    }

    /// Feed a slice of the HTTP/1.1 response. Appends any HTTP/2 frames it can
    /// produce to `out`. Safe to call repeatedly as bytes arrive.
    pub fn feed(self: *Transcoder, input: []const u8, out: *std.ArrayList(u8)) Error!void {
        var rest = input;
        while (rest.len > 0) {
            switch (self.phase) {
                .status_line, .headers => {
                    // Accumulate until we have the full header block (CRLFCRLF).
                    const boundary = try self.appendHead(rest);
                    if (boundary) |consumed| {
                        rest = rest[consumed..];
                        try self.parseHead();
                        try self.emitHeaders(out);
                        // emitHeaders sets the next phase (body_* or done).
                    } else {
                        return; // need more header bytes
                    }
                },
                .body_length => {
                    const take = @min(self.length_remaining, rest.len);
                    try self.body_pending.appendSlice(self.allocator, rest[0..take]);
                    self.length_remaining -= take;
                    rest = rest[take..];
                    try self.flushFullFrames(out);
                    if (self.length_remaining == 0) self.phase = .done;
                },
                .body_chunked => {
                    rest = try self.feedChunked(rest, out);
                },
                .done => return, // trailing bytes after a complete response: ignore
            }
        }
    }

    /// Signal that the dispatcher has produced the entire response. Flushes the
    /// remaining buffered body as the final DATA frame with END_STREAM (or, for
    /// an empty body where HEADERS already carried END_STREAM, does nothing).
    pub fn finish(self: *Transcoder, out: *std.ArrayList(u8)) Error!void {
        if (!self.headers_emitted) {
            // Degenerate: finished before a full header block arrived. Nothing
            // valid to send; the caller treats this as a torn-down stream.
            return;
        }
        if (self.end_stream_sent) return;
        // Emit remaining body (possibly empty) as the END_STREAM-bearing frame.
        try self.emitData(out, self.body_pending.items, true);
        self.body_pending.clearRetainingCapacity();
        self.end_stream_sent = true;
        self.phase = .done;
    }

    pub fn isDone(self: *const Transcoder) bool {
        return self.end_stream_sent;
    }

    // --- header accumulation -------------------------------------------------

    // Append bytes to head_buf; return the number of `input` bytes consumed up
    // to and including the CRLFCRLF terminator, or null if not yet seen.
    fn appendHead(self: *Transcoder, input: []const u8) Error!?usize {
        // Cap the header block to bound memory against a malformed feed.
        if (self.head_buf.items.len + input.len > h2.HTTP2_MAX_HEADER_BLOCK * 4) {
            return error.MalformedResponse;
        }
        const prev = self.head_buf.items.len;
        try self.head_buf.appendSlice(self.allocator, input);
        // Search for \r\n\r\n, starting a little before the new bytes in case
        // the terminator straddles the feed boundary.
        const search_from = if (prev >= 3) prev - 3 else 0;
        const buf = self.head_buf.items;
        if (std.mem.indexOfPos(u8, buf, search_from, "\r\n\r\n")) |idx| {
            const head_len = idx + 4;
            const consumed_from_input = head_len - prev;
            return consumed_from_input;
        }
        return null;
    }

    fn parseHead(self: *Transcoder) Error!void {
        const buf = self.head_buf.items;
        var lines = std.mem.splitSequence(u8, buf, "\r\n");

        const status_line = lines.next() orelse return error.MalformedResponse;
        // "HTTP/1.1 200 OK" → status code token.
        var sp = std.mem.splitScalar(u8, status_line, ' ');
        _ = sp.next() orelse return error.MalformedResponse; // version
        const code = sp.next() orelse return error.MalformedResponse;
        if (code.len != 3) return error.MalformedResponse;
        self.status = try self.allocator.dupe(u8, code);

        const status_code = std.fmt.parseInt(u16, code, 10) catch return error.MalformedResponse;
        // RFC 7230: 1xx, 204, 304 carry no body.
        if ((status_code >= 100 and status_code < 200) or status_code == 204 or status_code == 304) {
            self.no_body = true;
        }

        var chunked = false;
        while (lines.next()) |line| {
            if (line.len == 0) continue; // trailing empty from CRLFCRLF
            const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
            const raw_name = std.mem.trim(u8, line[0..colon], " \t");
            const raw_value = std.mem.trim(u8, line[colon + 1 ..], " \t");
            if (raw_name.len == 0) continue;

            // Lowercase the name (HPACK/H2 mandate; the encoder does not).
            const name = try self.allocator.alloc(u8, raw_name.len);
            errdefer self.allocator.free(name);
            for (raw_name, 0..) |ch, i| name[i] = std.ascii.toLower(ch);

            // Drop headers that are illegal / connection-specific in HTTP/2.
            if (isHopByHop(name)) {
                if (std.mem.eql(u8, name, "transfer-encoding") and
                    std.ascii.indexOfIgnoreCase(raw_value, "chunked") != null)
                {
                    chunked = true;
                }
                self.allocator.free(name);
                continue;
            }
            if (std.mem.eql(u8, name, "content-length")) {
                self.content_length = std.fmt.parseInt(usize, raw_value, 10) catch null;
                // content-length is also forwarded (it is legal and useful in
                // H2); fall through to append it.
            }

            const value = try self.allocator.dupe(u8, raw_value);
            try self.resp_headers.append(self.allocator, .{ .name = name, .value = value });
        }

        if (chunked) {
            self.phase = .body_chunked;
            self.chunk_state = .size_line;
        } else if (self.content_length) |cl| {
            self.length_remaining = cl;
            if (cl == 0) self.no_body = true;
            self.phase = .body_length;
        } else {
            // No length and not chunked: empty body (e.g. our internal 400/HEAD).
            self.no_body = true;
            self.phase = .body_length;
            self.length_remaining = 0;
        }
    }

    // Emit the HEADERS frame: HPACK-encode `:status` + forwarded headers and
    // wrap it. END_STREAM rides on HEADERS only when the body is known empty.
    fn emitHeaders(self: *Transcoder, out: *std.ArrayList(u8)) Error!void {
        if (self.headers_emitted) return;

        var hlist: std.ArrayList(h2_encoder.Header) = .empty;
        defer hlist.deinit(self.allocator);
        try hlist.append(self.allocator, .{ .name = ":status", .value = self.status });
        try hlist.appendSlice(self.allocator, self.resp_headers.items);

        const block = try h2_encoder.Encoder.encode(hlist.items, self.allocator);
        defer self.allocator.free(block);

        var flags: u8 = h2.HTTP2_FLAG_END_HEADERS;
        if (self.no_body) {
            flags |= h2.HTTP2_FLAG_END_STREAM;
            self.end_stream_sent = true;
            self.phase = .done;
        }
        const frame = h2.Frame.build(self.allocator, h2.HTTP2_FRAME_TYPE_HEADERS, flags, self.stream_id, block) catch
            return error.OutOfMemory;
        defer self.allocator.free(frame);
        try out.appendSlice(self.allocator, frame);
        self.headers_emitted = true;
    }

    // --- chunked de-framing --------------------------------------------------

    fn feedChunked(self: *Transcoder, input: []const u8, out: *std.ArrayList(u8)) Error![]const u8 {
        var rest = input;
        while (rest.len > 0) {
            switch (self.chunk_state) {
                .size_line => {
                    // Read up to CRLF, then parse the hex size (ignore ext after ';').
                    const nl = std.mem.indexOfScalar(u8, rest, '\n');
                    if (nl == null) {
                        try self.line_buf.appendSlice(self.allocator, rest);
                        if (self.line_buf.items.len > 64) return error.MalformedResponse;
                        return rest[rest.len..]; // consumed all, need more
                    }
                    try self.line_buf.appendSlice(self.allocator, rest[0 .. nl.? + 1]);
                    rest = rest[nl.? + 1 ..];
                    const line = std.mem.trim(u8, self.line_buf.items, "\r\n \t");
                    const semi = std.mem.indexOfScalar(u8, line, ';');
                    const hex = if (semi) |s| line[0..s] else line;
                    const size = std.fmt.parseInt(usize, std.mem.trim(u8, hex, " \t"), 16) catch
                        return error.MalformedResponse;
                    self.line_buf.clearRetainingCapacity();
                    if (size == 0) {
                        self.chunk_state = .trailer;
                    } else {
                        self.chunk_remaining = size;
                        self.chunk_state = .data;
                    }
                },
                .data => {
                    const take = @min(self.chunk_remaining, rest.len);
                    try self.body_pending.appendSlice(self.allocator, rest[0..take]);
                    self.chunk_remaining -= take;
                    rest = rest[take..];
                    try self.flushFullFrames(out);
                    if (self.chunk_remaining == 0) self.chunk_state = .data_crlf;
                },
                .data_crlf => {
                    // Consume the CRLF that follows chunk data.
                    if (rest[0] == '\r' or rest[0] == '\n') {
                        // Skip CR and/or LF tolerantly.
                        if (rest[0] == '\r') {
                            rest = rest[1..];
                            if (rest.len == 0) return rest;
                        }
                        if (rest.len > 0 and rest[0] == '\n') rest = rest[1..];
                        self.chunk_state = .size_line;
                    } else {
                        return error.MalformedResponse;
                    }
                },
                .trailer => {
                    // After the 0-size chunk: optional trailer headers then a
                    // final CRLF. We forward no trailers; just consume until the
                    // terminating blank line, then the body is complete.
                    const nl = std.mem.indexOfScalar(u8, rest, '\n');
                    if (nl == null) {
                        try self.line_buf.appendSlice(self.allocator, rest);
                        if (self.line_buf.items.len > h2.HTTP2_MAX_HEADER_BLOCK) return error.MalformedResponse;
                        return rest[rest.len..];
                    }
                    try self.line_buf.appendSlice(self.allocator, rest[0 .. nl.? + 1]);
                    rest = rest[nl.? + 1 ..];
                    const line = std.mem.trim(u8, self.line_buf.items, "\r\n \t");
                    self.line_buf.clearRetainingCapacity();
                    if (line.len == 0) {
                        // Blank line → end of trailers → body complete.
                        self.phase = .done;
                        return rest;
                    }
                    // Non-empty trailer line: ignore, keep reading.
                },
            }
        }
        return rest;
    }

    // --- DATA framing --------------------------------------------------------

    // Emit max-frame-size DATA frames while the pending buffer is large enough,
    // keeping a remainder for the final (END_STREAM) frame.
    fn flushFullFrames(self: *Transcoder, out: *std.ArrayList(u8)) Error!void {
        while (self.body_pending.items.len > self.max_frame_size) {
            try self.emitData(out, self.body_pending.items[0..self.max_frame_size], false);
            const rem = self.body_pending.items.len - self.max_frame_size;
            std.mem.copyForwards(u8, self.body_pending.items[0..rem], self.body_pending.items[self.max_frame_size..]);
            self.body_pending.shrinkRetainingCapacity(rem);
        }
    }

    fn emitData(self: *Transcoder, out: *std.ArrayList(u8), payload: []const u8, end_stream: bool) Error!void {
        const flags: u8 = if (end_stream) h2.HTTP2_FLAG_END_STREAM else 0;
        const frame = h2.Frame.build(self.allocator, h2.HTTP2_FRAME_TYPE_DATA, flags, self.stream_id, payload) catch
            return error.OutOfMemory;
        defer self.allocator.free(frame);
        try out.appendSlice(self.allocator, frame);
    }
};

fn isHopByHop(name: []const u8) bool {
    const hop = [_][]const u8{ "connection", "keep-alive", "transfer-encoding", "upgrade", "proxy-connection" };
    for (hop) |h| {
        if (std.mem.eql(u8, name, h)) return true;
    }
    return false;
}

// ===========================================================================
// Tests — decode the transcoder's output with the real HPACK decoder + frame
// parser to assert wire correctness end to end.
// ===========================================================================

const testing = std.testing;

// Walk a buffer of concatenated frames, returning them in order.
const ParsedFrame = struct { ftype: u8, flags: u8, stream_id: u31, payload: []const u8 };

fn parseFrames(a: std.mem.Allocator, buf: []const u8, out: *std.ArrayList(ParsedFrame)) !void {
    var i: usize = 0;
    while (i + 9 <= buf.len) {
        const f = h2.Frame.parse(buf[i..]).?;
        const start = i + 9;
        const end = start + f.length;
        try out.append(a, .{ .ftype = f.frame_type, .flags = f.flags, .stream_id = f.stream_id, .payload = buf[start..end] });
        i = end;
    }
    try testing.expectEqual(buf.len, i); // no trailing garbage
}

fn decodeHeaders(a: std.mem.Allocator, block: []const u8, out: *std.ArrayList(h2.Header)) !void {
    var dec = h2.Decoder.init(a);
    defer dec.deinit();
    try dec.decode(block, out);
}

test "single-shot Content-Length response → HEADERS + DATA(END_STREAM)" {
    const a = testing.allocator;
    var tc = Transcoder.init(a, 1, 16384);
    defer tc.deinit();
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(a);

    const resp = "HTTP/1.1 200 OK\r\nServer: saltare\r\nContent-Type: text/plain\r\nContent-Length: 5\r\n\r\nhello";
    try tc.feed(resp, &out);
    try tc.finish(&out);
    try testing.expect(tc.isDone());

    var frames: std.ArrayList(ParsedFrame) = .empty;
    defer frames.deinit(a);
    try parseFrames(a, out.items, &frames);

    try testing.expectEqual(@as(usize, 2), frames.items.len);
    // HEADERS, END_HEADERS set, END_STREAM NOT set (body follows).
    try testing.expectEqual(h2.HTTP2_FRAME_TYPE_HEADERS, frames.items[0].ftype);
    try testing.expect(frames.items[0].flags & h2.HTTP2_FLAG_END_HEADERS != 0);
    try testing.expect(frames.items[0].flags & h2.HTTP2_FLAG_END_STREAM == 0);

    var hdrs: std.ArrayList(h2.Header) = .empty;
    defer hdrs.deinit(a);
    try decodeHeaders(a, frames.items[0].payload, &hdrs);
    try testing.expectEqualStrings(":status", hdrs.items[0].name);
    try testing.expectEqualStrings("200", hdrs.items[0].value);
    // transfer-encoding/connection absent; content-type present, lowercased.
    var saw_ct = false;
    for (hdrs.items) |h| {
        try testing.expect(!std.mem.eql(u8, h.name, "connection"));
        if (std.mem.eql(u8, h.name, "content-type")) saw_ct = true;
    }
    try testing.expect(saw_ct);

    // DATA with END_STREAM carrying the body.
    try testing.expectEqual(h2.HTTP2_FRAME_TYPE_DATA, frames.items[1].ftype);
    try testing.expect(frames.items[1].flags & h2.HTTP2_FLAG_END_STREAM != 0);
    try testing.expectEqualStrings("hello", frames.items[1].payload);
}

test "empty-body response → HEADERS with END_STREAM, no DATA" {
    const a = testing.allocator;
    var tc = Transcoder.init(a, 3, 16384);
    defer tc.deinit();
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(a);

    const resp = "HTTP/1.1 204 No Content\r\nServer: saltare\r\n\r\n";
    try tc.feed(resp, &out);
    try tc.finish(&out);

    var frames: std.ArrayList(ParsedFrame) = .empty;
    defer frames.deinit(a);
    try parseFrames(a, out.items, &frames);
    try testing.expectEqual(@as(usize, 1), frames.items.len);
    try testing.expectEqual(h2.HTTP2_FRAME_TYPE_HEADERS, frames.items[0].ftype);
    try testing.expect(frames.items[0].flags & h2.HTTP2_FLAG_END_STREAM != 0);
}

test "chunked streaming response is de-framed into DATA frames" {
    const a = testing.allocator;
    var tc = Transcoder.init(a, 5, 16384);
    defer tc.deinit();
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(a);

    // chunks: "Wiki" (4) + "pedia" (5) + 0-terminator.
    const resp = "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n" ++
        "4\r\nWiki\r\n5\r\npedia\r\n0\r\n\r\n";
    try tc.feed(resp, &out);
    try tc.finish(&out);

    var frames: std.ArrayList(ParsedFrame) = .empty;
    defer frames.deinit(a);
    try parseFrames(a, out.items, &frames);

    // HEADERS then DATA frame(s); reassembled body == "Wikipedia".
    try testing.expectEqual(h2.HTTP2_FRAME_TYPE_HEADERS, frames.items[0].ftype);
    var body: std.ArrayList(u8) = .empty;
    defer body.deinit(a);
    var last_end = false;
    for (frames.items[1..]) |f| {
        try testing.expectEqual(h2.HTTP2_FRAME_TYPE_DATA, f.ftype);
        try body.appendSlice(a, f.payload);
        last_end = f.flags & h2.HTTP2_FLAG_END_STREAM != 0;
    }
    try testing.expectEqualStrings("Wikipedia", body.items);
    try testing.expect(last_end);
    // transfer-encoding must NOT appear in the emitted headers.
    var hdrs: std.ArrayList(h2.Header) = .empty;
    defer hdrs.deinit(a);
    try decodeHeaders(a, frames.items[0].payload, &hdrs);
    for (hdrs.items) |h| try testing.expect(!std.mem.eql(u8, h.name, "transfer-encoding"));
}

test "body split across feeds and header boundary straddling feeds" {
    const a = testing.allocator;
    var tc = Transcoder.init(a, 7, 16384);
    defer tc.deinit();
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(a);

    // Feed the response one byte at a time — exercises every resumption point.
    const resp = "HTTP/1.1 200 OK\r\nContent-Length: 11\r\n\r\nhello world";
    for (resp) |ch| {
        try tc.feed(&[_]u8{ch}, &out);
    }
    try tc.finish(&out);

    var frames: std.ArrayList(ParsedFrame) = .empty;
    defer frames.deinit(a);
    try parseFrames(a, out.items, &frames);
    var body: std.ArrayList(u8) = .empty;
    defer body.deinit(a);
    for (frames.items[1..]) |f| try body.appendSlice(a, f.payload);
    try testing.expectEqualStrings("hello world", body.items);
}

test "body larger than max_frame_size is split into multiple DATA frames" {
    const a = testing.allocator;
    // Floor is 16384; use that. Body = 40000 bytes → 3 frames (16384,16384,7232).
    var tc = Transcoder.init(a, 1, 16384);
    defer tc.deinit();
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(a);

    var resp: std.ArrayList(u8) = .empty;
    defer resp.deinit(a);
    try resp.appendSlice(a, "HTTP/1.1 200 OK\r\nContent-Length: 40000\r\n\r\n");
    try resp.appendNTimes(a, 'z', 40000);
    try tc.feed(resp.items, &out);
    try tc.finish(&out);

    var frames: std.ArrayList(ParsedFrame) = .empty;
    defer frames.deinit(a);
    try parseFrames(a, out.items, &frames);

    var data_frames: usize = 0;
    var total: usize = 0;
    var last_end = false;
    for (frames.items) |f| {
        if (f.ftype == h2.HTTP2_FRAME_TYPE_DATA) {
            data_frames += 1;
            total += f.payload.len;
            try testing.expect(f.payload.len <= 16384);
            last_end = f.flags & h2.HTTP2_FLAG_END_STREAM != 0;
        }
    }
    try testing.expectEqual(@as(usize, 40000), total);
    try testing.expectEqual(@as(usize, 3), data_frames);
    try testing.expect(last_end);
}
