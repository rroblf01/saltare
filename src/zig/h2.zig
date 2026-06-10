// HTTP/2 protocol implementation (RFC 7540 + RFC 7541).
//
// RAM-optimized: minimal allocations, uses shared pool for buffers.
// v1.9: HTTP/2 support with HPACK compression.

const std = @import("std");
const h2_static = @import("h2_static.zig");
const huffman = @import("huffman.zig");

pub const HTTP2_FRAME_TYPE_DATA: u8 = 0x0;
pub const HTTP2_FRAME_TYPE_HEADERS: u8 = 0x1;
pub const HTTP2_FRAME_TYPE_PRIORITY: u8 = 0x2;
pub const HTTP2_FRAME_TYPE_RST_STREAM: u8 = 0x3;
pub const HTTP2_FRAME_TYPE_SETTINGS: u8 = 0x4;
pub const HTTP2_FRAME_TYPE_PING: u8 = 0x6;
pub const HTTP2_FRAME_TYPE_GOAWAY: u8 = 0x7;
pub const HTTP2_FRAME_TYPE_WINDOW_UPDATE: u8 = 0x8;
pub const HTTP2_FRAME_TYPE_CONTINUATION: u8 = 0x9;

pub const HTTP2_SETTINGS_MAX_CONCURRENT_STREAMS: u32 = 100;
pub const HTTP2_SETTINGS_INITIAL_WINDOW_SIZE: u32 = 65535;
pub const HTTP2_SETTINGS_MAX_FRAME_SIZE: u32 = 16777215;
pub const HTTP2_SETTINGS_MAX_HEADER_TABLE_SIZE: u32 = 4096;

pub const HTTP2_SETTINGS_ID_HEADER_TABLE_SIZE: u16 = 0x1;
pub const HTTP2_SETTINGS_ID_ENABLE_PUSH: u16 = 0x2;
pub const HTTP2_SETTINGS_ID_MAX_CONCURRENT_STREAMS: u16 = 0x3;
pub const HTTP2_SETTINGS_ID_INITIAL_WINDOW_SIZE: u16 = 0x4;
pub const HTTP2_SETTINGS_ID_MAX_FRAME_SIZE: u16 = 0x5;
pub const HTTP2_SETTINGS_ID_MAX_HEADER_LIST_SIZE: u16 = 0x6;

pub const HTTP2_FLAG_END_STREAM: u8 = 0x1;
pub const HTTP2_FLAG_END_HEADERS: u8 = 0x4;
pub const HTTP2_FLAG_ACK: u8 = 0x1;
pub const HTTP2_FLAG_PADDED: u8 = 0x8;
pub const HTTP2_FLAG_PRIORITY: u8 = 0x20;

pub const HTTP2_MAGIC = "PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n";
pub const HTTP2_SETTINGS_ACK = [_]u8{ 0x0, 0x0, 0x0, HTTP2_FRAME_TYPE_SETTINGS, HTTP2_FLAG_ACK, 0x0, 0x0, 0x0, 0x0 };

pub const H2Error = error{
    CompressionError,
    ProtocolError,
    FlowControlError,
    FrameSizeError,
    IncompleteFrame,
    InvalidStreamState,
    StreamClosed,
    SettingsRejected,
    OutOfMemory,
};

pub const Header = struct {
    name: []const u8,
    value: []const u8,
};

pub const StreamState = enum {
    Idle,
    Open,
    ReservedLocal,
    ReservedRemote,
    HalfClosedLocal,
    HalfClosedRemote,
    Closed,
};

pub const Frame = struct {
    length: u24,
    frame_type: u8,
    flags: u8,
    stream_id: u31,

    pub fn parse(data: []const u8) ?Frame {
        if (data.len < 9) return null;
        const length = (@as(u24, data[0]) << 16) | (@as(u24, data[1]) << 8) | @as(u24, data[2]);
        return Frame{
            .length = length,
            .frame_type = data[3],
            .flags = data[4],
            .stream_id = @as(u31, @truncate(std.mem.readInt(u32, data[5..9], .big) & 0x7FFFFFFF)),
        };
    }

    pub fn build(allocator: std.mem.Allocator, frame_type: u8, flags: u8, stream_id: u31, payload: []const u8) ![]u8 {
        if (payload.len > HTTP2_SETTINGS_MAX_FRAME_SIZE) return error.FrameSizeError;
        var frame = try allocator.alloc(u8, 9 + payload.len);
        frame[0] = @as(u8, @truncate(payload.len >> 16));
        frame[1] = @as(u8, @truncate(payload.len >> 8));
        frame[2] = @as(u8, @truncate(payload.len));
        frame[3] = frame_type;
        frame[4] = flags;
        std.mem.writeInt(u32, frame[5..9], @as(u32, stream_id), .big);
        @memcpy(frame[9..], payload);
        return frame;
    }
};

pub const StreamContext = struct {
    id: u31,
    state: StreamState = .Idle,
    window_size: u32 = HTTP2_SETTINGS_INITIAL_WINDOW_SIZE,
    end_stream: bool = false,
    header_list: []Header = &.{},
    // Whether this stream is currently counted against active_stream_count
    // (i.e. opened and not yet half-closed/reset). See MAX_CONCURRENT_STREAMS
    // enforcement in handleHeaders/handleData/handleRstStream.
    counted: bool = false,
};

// RFC 7540 §6.9.1: a flow-control window MUST NOT exceed 2^31-1.
pub const HTTP2_MAX_WINDOW: u32 = 0x7FFFFFFF;

// Upper bound on an assembled HEADERS+CONTINUATION block. Bounds the
// CONTINUATION-flood DoS (CVE-2024-27316 class) — a peer cannot make us
// buffer unbounded header bytes across CONTINUATION frames.
pub const HTTP2_MAX_HEADER_BLOCK: usize = 64 * 1024;

// RFC 7540 error codes.
pub const HTTP2_ERROR_NO_ERROR: u32 = 0x0;
pub const HTTP2_ERROR_PROTOCOL_ERROR: u32 = 0x1;
pub const HTTP2_ERROR_FLOW_CONTROL_ERROR: u32 = 0x3;
pub const HTTP2_ERROR_FRAME_SIZE_ERROR: u32 = 0x6;
pub const HTTP2_ERROR_REFUSED_STREAM: u32 = 0x7;

pub const Settings = struct {
    header_table_size: u32 = HTTP2_SETTINGS_MAX_HEADER_TABLE_SIZE,
    enable_push: u32 = 1,
    max_concurrent_streams: u32 = HTTP2_SETTINGS_MAX_CONCURRENT_STREAMS,
    initial_window_size: u32 = HTTP2_SETTINGS_INITIAL_WINDOW_SIZE,
    max_frame_size: u32 = HTTP2_SETTINGS_MAX_FRAME_SIZE,
    max_header_list_size: u32 = 16777215,
};

// HPACK decoder (RFC 7541). v1.10 rewrite:
//   * Correct N-bit prefix integer decoding (was: ad-hoc 2-byte length).
//   * Huffman string decoding (was: ignored the H bit → garbage on every
//     real client, which all Huffman-encode by default).
//   * A working dynamic table that actually stores entries with owned
//     copies and RFC-correct indexing/eviction (was: a no-op that bumped
//     a counter, so cross-request indexing silently dropped headers).
//
// Lifetime model: literal and Huffman-decoded strings are allocated from a
// per-decode arena (`scratch`) reset at the start of each decode(). The
// caller (server.zig doReadHttp2) consumes the returned header list
// synchronously — copying names/values into Python objects — before the
// next frame is decoded, so the arena's contents outlive every read of the
// returned slices. Dynamic-table entries are owned by the long-lived
// allocator and survive across frames.
const DynEntry = struct { name: []u8, value: []u8 };

pub const Decoder = struct {
    allocator: std.mem.Allocator,
    scratch: std.heap.ArenaAllocator,
    table: std.ArrayList(DynEntry) = .empty,
    table_size: u32 = 0,
    // Current dynamic-table size limit; lowered by a "dynamic table size
    // update" instruction. Never exceeds `limit`.
    max_size: u32 = HTTP2_SETTINGS_MAX_HEADER_TABLE_SIZE,
    // Hard upper bound advertised in SETTINGS_HEADER_TABLE_SIZE.
    limit: u32 = HTTP2_SETTINGS_MAX_HEADER_TABLE_SIZE,

    pub fn init(allocator: std.mem.Allocator) Decoder {
        return .{ .allocator = allocator, .scratch = std.heap.ArenaAllocator.init(allocator) };
    }

    pub fn deinit(self: *Decoder) void {
        for (self.table.items) |e| {
            self.allocator.free(e.name);
            self.allocator.free(e.value);
        }
        self.table.deinit(self.allocator);
        self.scratch.deinit();
    }

    fn evictAll(self: *Decoder) void {
        for (self.table.items) |e| {
            self.allocator.free(e.name);
            self.allocator.free(e.value);
        }
        self.table.clearRetainingCapacity();
        self.table_size = 0;
    }

    fn setMaxSize(self: *Decoder, new_size: u32) void {
        self.max_size = new_size;
        while (self.table_size > self.max_size and self.table.items.len > 0) {
            const old = self.table.pop().?;
            self.table_size -= @intCast(32 + old.name.len + old.value.len);
            self.allocator.free(old.name);
            self.allocator.free(old.value);
        }
    }

    fn addEntry(self: *Decoder, name: []const u8, value: []const u8) H2Error!void {
        const entry_size: u32 = @intCast(32 + name.len + value.len);
        // RFC 7541 §4.4: an entry larger than the table empties it and is
        // not added. (Dupe BEFORE eviction is moot here since nothing is
        // inserted.)
        if (entry_size > self.max_size) {
            self.evictAll();
            return;
        }
        // Dupe before evicting — `name`/`value` may alias a dynamic-table
        // entry that eviction would free.
        const n = self.allocator.dupe(u8, name) catch return error.CompressionError;
        errdefer self.allocator.free(n);
        const v = self.allocator.dupe(u8, value) catch return error.CompressionError;
        errdefer self.allocator.free(v);
        while (self.table_size + entry_size > self.max_size and self.table.items.len > 0) {
            const old = self.table.pop().?;
            self.table_size -= @intCast(32 + old.name.len + old.value.len);
            self.allocator.free(old.name);
            self.allocator.free(old.value);
        }
        // Newest entry at index 0 → HPACK index 62 maps to table[0].
        self.table.insert(self.allocator, 0, .{ .name = n, .value = v }) catch return error.CompressionError;
        self.table_size += entry_size;
    }

    fn resolveIndex(self: *Decoder, index: usize) H2Error!Header {
        if (index == 0) return error.CompressionError;
        if (index < 62) {
            if (h2_static.staticEntry(@intCast(index))) |entry| {
                return .{ .name = entry.name, .value = entry.value };
            }
            return error.CompressionError;
        }
        const dyn = index - 62;
        if (dyn >= self.table.items.len) return error.CompressionError;
        const e = self.table.items[dyn];
        return .{ .name = e.name, .value = e.value };
    }

    pub fn decode(self: *Decoder, input: []const u8, out: *std.ArrayList(Header)) H2Error!void {
        _ = self.scratch.reset(.retain_capacity);
        const sa = self.scratch.allocator();
        var i: usize = 0;

        while (i < input.len) {
            const first = input[i];
            i += 1;

            if (first & 0x80 != 0) {
                // Indexed Header Field — 7-bit prefix.
                const index = try decodeInteger(input, &i, first & 0x7F, 7);
                try out.append(self.allocator, try self.resolveIndex(index));
            } else if (first & 0x40 != 0) {
                // Literal Header Field with Incremental Indexing — 6-bit name index.
                const idx = try decodeInteger(input, &i, first & 0x3F, 6);
                const name = if (idx != 0) (try self.resolveIndex(idx)).name else try self.decodeString(sa, input, &i);
                const value = try self.decodeString(sa, input, &i);
                try self.addEntry(name, value);
                try out.append(self.allocator, .{ .name = name, .value = value });
            } else if (first & 0x20 != 0) {
                // Dynamic Table Size Update — 5-bit prefix.
                const size = try decodeInteger(input, &i, first & 0x1F, 5);
                if (size > self.limit) return error.CompressionError;
                self.setMaxSize(@intCast(size));
            } else {
                // Literal without Indexing (0x00) / Never Indexed (0x10) — 4-bit name index.
                const idx = try decodeInteger(input, &i, first & 0x0F, 4);
                const name = if (idx != 0) (try self.resolveIndex(idx)).name else try self.decodeString(sa, input, &i);
                const value = try self.decodeString(sa, input, &i);
                try out.append(self.allocator, .{ .name = name, .value = value });
            }
        }
    }

    // RFC 7541 §5.1 prefix-integer decode. `prefix_val` is the low N bits of
    // the already-consumed first byte; `i` points at the first continuation
    // byte (if any).
    fn decodeInteger(input: []const u8, i: *usize, prefix_val: u8, comptime prefix_bits: u4) H2Error!usize {
        const max_prefix: usize = (@as(usize, 1) << prefix_bits) - 1;
        if (prefix_val < max_prefix) return prefix_val;
        var value: usize = max_prefix;
        var m: u6 = 0;
        while (true) {
            if (i.* >= input.len) return error.CompressionError;
            const b = input[i.*];
            i.* += 1;
            value += @as(usize, b & 0x7F) << m;
            if (b & 0x80 == 0) break;
            m += 7;
            // Header indices / lengths never need more than ~5 octets; cap to
            // stop a malicious unbounded continuation run (and usize overflow).
            if (m > 28) return error.CompressionError;
        }
        return value;
    }

    fn decodeString(_: *Decoder, sa: std.mem.Allocator, input: []const u8, i: *usize) H2Error![]const u8 {
        if (i.* >= input.len) return error.CompressionError;
        const first = input[i.*];
        i.* += 1;
        const is_huffman = (first & 0x80) != 0;
        const len = try decodeInteger(input, i, first & 0x7F, 7);
        if (i.* + len > input.len) return error.CompressionError;
        const raw = input[i.* .. i.* + len];
        i.* += len;
        if (is_huffman) {
            return huffman.decode(sa, raw) catch return error.CompressionError;
        }
        // Copy literals into the scratch arena for a uniform lifetime and to
        // avoid aliasing the read buffer (which the bridge lowercases in place).
        return sa.dupe(u8, raw) catch return error.CompressionError;
    }
};

pub const FrameResult = struct {
    headers: ?std.ArrayList(Header) = null,
    data: ?[]const u8 = null,
    stream_id: u31 = 0,
    end_stream: bool = false,
    settings_ack: bool = false,
    ping: ?[]const u8 = null,
    ping_ack: bool = false,
    goaway: bool = false,
    goaway_stream_id: u31 = 0,
    stream_closed: u31 = 0,
    need_window_update: bool = false,
    // Non-zero → server must emit RST_STREAM for this stream with `rst_error`
    // and NOT dispatch it (e.g. REFUSED_STREAM when over the stream cap).
    rst_stream: u31 = 0,
    rst_error: u32 = 0,
    // Bytes of DATA consumed this frame, for connection-level WINDOW_UPDATE.
    data_consumed: u32 = 0,
};

pub const Connection = struct {
    streams: std.AutoHashMap(u31, StreamContext),
    decoder: Decoder,
    settings: Settings = .{},
    preface_received: bool = false,
    settings_acked: bool = false,
    active_stream_count: u32 = 0,
    connection_window: u32 = HTTP2_SETTINGS_INITIAL_WINDOW_SIZE,
    allocator: std.mem.Allocator,
    // CONTINUATION reassembly: while a HEADERS frame lacks END_HEADERS, its
    // (and following CONTINUATION frames') header-block fragments accumulate
    // here until END_HEADERS arrives. While set, only CONTINUATION frames on
    // the same stream are legal (RFC 7540 §6.10).
    hdr_pending: std.ArrayList(u8) = .empty,
    hdr_stream: u31 = 0,
    hdr_end_stream: bool = false,
    expecting_continuation: bool = false,

    pub fn init(allocator: std.mem.Allocator) Connection {
        return Connection{
            .streams = std.AutoHashMap(u31, StreamContext).init(allocator),
            .decoder = Decoder.init(allocator),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Connection) void {
        self.streams.deinit();
        self.decoder.deinit();
        self.hdr_pending.deinit(self.allocator);
    }

    pub fn expectPreface(self: *Connection, data: []const u8) H2Error!bool {
        if (self.preface_received) return true;
        if (data.len < HTTP2_MAGIC.len) return error.IncompleteFrame;
        if (!std.mem.startsWith(u8, data, HTTP2_MAGIC)) {
            return error.ProtocolError;
        }
        self.preface_received = true;
        return true;
    }

    pub fn processFrame(self: *Connection, data: []const u8) H2Error!?FrameResult {
        const frame = Frame.parse(data) orelse return error.IncompleteFrame;
        if (data.len < 9 + frame.length) return error.IncompleteFrame;
        const payload = data[9..][0..frame.length];

        // RFC 7540 §6.10: while a header block is open, the only legal frame
        // is a CONTINUATION on the same stream. Anything else is a connection
        // error. This also prevents interleaving that would corrupt HPACK
        // decoder state.
        if (self.expecting_continuation and frame.frame_type != HTTP2_FRAME_TYPE_CONTINUATION) {
            return error.ProtocolError;
        }

        return switch (frame.frame_type) {
            HTTP2_FRAME_TYPE_SETTINGS => self.handleSettings(frame, payload),
            HTTP2_FRAME_TYPE_HEADERS => self.handleHeaders(frame, payload),
            HTTP2_FRAME_TYPE_DATA => self.handleData(frame, payload),
            HTTP2_FRAME_TYPE_WINDOW_UPDATE => self.handleWindowUpdate(frame, payload),
            HTTP2_FRAME_TYPE_PING => self.handlePing(frame, payload),
            HTTP2_FRAME_TYPE_RST_STREAM => self.handleRstStream(frame, payload),
            HTTP2_FRAME_TYPE_GOAWAY => self.handleGoAway(frame, payload),
            HTTP2_FRAME_TYPE_PRIORITY => self.handlePriority(frame, payload),
            HTTP2_FRAME_TYPE_CONTINUATION => self.handleContinuation(frame, payload),
            else => null,
        };
    }

    fn handleSettings(self: *Connection, frame: Frame, payload: []const u8) H2Error!?FrameResult {
        if (frame.stream_id != 0) return error.ProtocolError;
        if (frame.flags & HTTP2_FLAG_ACK != 0) {
            // An ACK carries no payload (RFC 7540 §6.5).
            if (payload.len != 0) return error.FrameSizeError;
            self.settings_acked = true;
            return null;
        }
        // A SETTINGS frame payload is a sequence of 6-octet entries.
        if (payload.len % 6 != 0) return error.FrameSizeError;
        var i: usize = 0;
        while (i + 6 <= payload.len) : (i += 6) {
            const id = std.mem.readInt(u16, payload[i..][0..2], .big);
            const value = std.mem.readInt(u32, payload[i + 2 ..][0..4], .big);
            switch (id) {
                HTTP2_SETTINGS_ID_INITIAL_WINDOW_SIZE => {
                    if (value > HTTP2_MAX_WINDOW) return error.FlowControlError;
                    self.settings.initial_window_size = value;
                },
                HTTP2_SETTINGS_ID_HEADER_TABLE_SIZE => self.settings.header_table_size = value,
                HTTP2_SETTINGS_ID_MAX_FRAME_SIZE => {
                    // RFC 7540 §6.5.2: valid range is 2^14..2^24-1.
                    if (value < 16384 or value > HTTP2_SETTINGS_MAX_FRAME_SIZE) return error.ProtocolError;
                    self.settings.max_frame_size = value;
                },
                else => {}, // unknown settings ignored
            }
        }
        return FrameResult{ .settings_ack = true };
    }

    fn handleHeaders(self: *Connection, frame: Frame, payload: []const u8) H2Error!?FrameResult {
        if (frame.stream_id == 0) return error.ProtocolError;
        if (frame.stream_id & 1 == 0) return error.ProtocolError;

        var offset: usize = 0;
        if (frame.flags & HTTP2_FLAG_PADDED != 0) {
            if (offset >= payload.len) return error.ProtocolError;
            offset += 1;
            if (offset + payload[offset - 1] >= payload.len) return error.ProtocolError;
        }
        if (frame.flags & HTTP2_FLAG_PRIORITY != 0) {
            if (offset + 5 > payload.len) return error.ProtocolError;
            offset += 5;
        }
        const headers_data = payload[offset..];
        const end_stream = frame.flags & HTTP2_FLAG_END_STREAM != 0;
        const end_headers = frame.flags & HTTP2_FLAG_END_HEADERS != 0;

        // Stream-concurrency cap (RFC 7540 §5.1.2). A brand-new stream that
        // would stay open (no END_STREAM) is refused once we're at the cap —
        // this is the bound on the HEADERS-flood DoS.
        const is_new = self.streams.getPtr(frame.stream_id) == null;
        if (is_new and !end_stream and self.active_stream_count >= self.settings.max_concurrent_streams) {
            return FrameResult{ .rst_stream = frame.stream_id, .rst_error = HTTP2_ERROR_REFUSED_STREAM };
        }

        if (!end_headers) {
            // Begin CONTINUATION reassembly.
            if (headers_data.len > HTTP2_MAX_HEADER_BLOCK) return error.CompressionError;
            self.hdr_pending.clearRetainingCapacity();
            try self.hdr_pending.appendSlice(self.allocator, headers_data);
            self.hdr_stream = frame.stream_id;
            self.hdr_end_stream = end_stream;
            self.expecting_continuation = true;
            return null;
        }

        return self.dispatchHeaderBlock(frame.stream_id, end_stream, headers_data);
    }

    fn handleContinuation(self: *Connection, frame: Frame, payload: []const u8) H2Error!?FrameResult {
        if (frame.stream_id == 0) return error.ProtocolError;
        if (!self.expecting_continuation or frame.stream_id != self.hdr_stream) {
            return error.ProtocolError;
        }
        if (self.hdr_pending.items.len + payload.len > HTTP2_MAX_HEADER_BLOCK) {
            return error.CompressionError;
        }
        try self.hdr_pending.appendSlice(self.allocator, payload);
        if (frame.flags & HTTP2_FLAG_END_HEADERS == 0) {
            return null; // more CONTINUATION frames to come
        }
        self.expecting_continuation = false;
        return self.dispatchHeaderBlock(self.hdr_stream, self.hdr_end_stream, self.hdr_pending.items);
    }

    // Decode an assembled header block and register/refresh its stream.
    fn dispatchHeaderBlock(self: *Connection, stream_id: u31, end_stream: bool, block: []const u8) H2Error!?FrameResult {
        var headers: std.ArrayList(Header) = .empty;
        errdefer headers.deinit(self.allocator);
        try self.decoder.decode(block, &headers);

        if (self.streams.getPtr(stream_id)) |stream| {
            stream.end_stream = end_stream;
            stream.state = if (end_stream) .HalfClosedRemote else .Open;
            if (end_stream and stream.counted) {
                stream.counted = false;
                self.active_stream_count -= 1;
            }
        } else {
            var sc = StreamContext{ .id = stream_id, .state = if (end_stream) .HalfClosedRemote else .Open };
            sc.end_stream = end_stream;
            if (!end_stream) {
                sc.counted = true;
                self.active_stream_count += 1;
            }
            try self.streams.put(stream_id, sc);
        }

        return FrameResult{
            .headers = headers,
            .stream_id = stream_id,
            .end_stream = end_stream,
        };
    }

    fn handleData(self: *Connection, frame: Frame, payload: []const u8) H2Error!?FrameResult {
        if (frame.stream_id == 0) return error.ProtocolError;
        const len: u32 = @intCast(payload.len);
        // Flow control (RFC 7540 §6.9). saltare hands DATA to the app
        // synchronously, so each frame is consumed immediately and both
        // windows are replenished via WINDOW_UPDATE (see server.zig). The
        // windows therefore stay at their advertised size; a frame larger
        // than the current window is a protocol violation by the peer.
        if (len > self.connection_window) return error.FlowControlError;
        if (self.streams.getPtr(frame.stream_id)) |stream| {
            if (len > stream.window_size) return error.FlowControlError;
            const end_stream = frame.flags & HTTP2_FLAG_END_STREAM != 0;
            if (end_stream) {
                stream.state = .HalfClosedRemote;
                stream.end_stream = true;
                if (stream.counted) {
                    stream.counted = false;
                    self.active_stream_count -= 1;
                }
            }
            return FrameResult{
                .data = payload,
                .stream_id = frame.stream_id,
                .end_stream = end_stream,
                .need_window_update = len > 0,
                .data_consumed = len,
            };
        }
        return error.StreamClosed;
    }

    fn handleWindowUpdate(self: *Connection, frame: Frame, payload: []const u8) H2Error!?FrameResult {
        if (payload.len != 4) return error.FrameSizeError;
        const increment = std.mem.readInt(u32, payload[0..4], .big) & 0x7FFFFFFF;
        if (increment == 0) return error.ProtocolError;
        if (frame.stream_id == 0) {
            // RFC 7540 §6.9.1: window MUST NOT exceed 2^31-1.
            if (self.connection_window > HTTP2_MAX_WINDOW - increment) return error.FlowControlError;
            self.connection_window += increment;
        } else if (self.streams.getPtr(frame.stream_id)) |stream| {
            if (stream.window_size > HTTP2_MAX_WINDOW - increment) return error.FlowControlError;
            stream.window_size += increment;
        }
        return null;
    }

    fn handlePing(_: *Connection, frame: Frame, payload: []const u8) H2Error!?FrameResult {
        if (frame.stream_id != 0) return error.ProtocolError;
        if (payload.len != 8) return error.FrameSizeError;
        if (frame.flags & HTTP2_FLAG_ACK == 0) {
            return FrameResult{ .ping = payload, .ping_ack = true };
        }
        return null;
    }

    fn handleRstStream(self: *Connection, frame: Frame, payload: []const u8) H2Error!?FrameResult {
        if (frame.stream_id == 0) return error.ProtocolError;
        if (payload.len != 4) return error.FrameSizeError;
        if (self.streams.getPtr(frame.stream_id)) |stream| {
            if (stream.counted) {
                stream.counted = false;
                self.active_stream_count -= 1;
            }
        }
        _ = self.streams.remove(frame.stream_id);
        return FrameResult{ .stream_closed = frame.stream_id };
    }

    fn handleGoAway(_: *Connection, frame: Frame, _: []const u8) H2Error!?FrameResult {
        return FrameResult{ .goaway = true, .goaway_stream_id = frame.stream_id };
    }

    fn handlePriority(_: *Connection, frame: Frame, _: []const u8) H2Error!?FrameResult {
        if (frame.stream_id == 0) return error.ProtocolError;
        return null;
    }

    pub fn buildSettingsAck(_: *Connection) []const u8 {
        return &HTTP2_SETTINGS_ACK;
    }

    pub fn buildRstStream(self: *Connection, stream_id: u31, error_code: u32) (H2Error || error{OutOfMemory})![]u8 {
        var payload: [4]u8 = undefined;
        std.mem.writeInt(u32, &payload, error_code, .big);
        return Frame.build(self.allocator, HTTP2_FRAME_TYPE_RST_STREAM, 0, stream_id, &payload);
    }

    pub fn buildWindowUpdate(self: *Connection, stream_id: u31, increment: u31) (H2Error || error{OutOfMemory})![]u8 {
        var payload: [4]u8 = undefined;
        std.mem.writeInt(u32, &payload, increment, .big);
        return Frame.build(self.allocator, HTTP2_FRAME_TYPE_WINDOW_UPDATE, 0, stream_id, &payload);
    }

    pub fn buildGoAway(self: *Connection, last_stream_id: u31, error_code: u32) (H2Error || error{OutOfMemory})![]u8 {
        var payload: [8]u8 = undefined;
        std.mem.writeInt(u32, payload[0..4], last_stream_id, .big);
        std.mem.writeInt(u32, payload[4..8], error_code, .big);
        return Frame.build(self.allocator, HTTP2_FRAME_TYPE_GOAWAY, 0, 0, &payload);
    }
};

test "HPACK static table" {
    for (1..62) |i| {
        try std.testing.expect(h2_static.staticEntry(@intCast(i)) != null);
    }
    try std.testing.expect(h2_static.staticEntry(0) == null);
}

test "Frame parse" {
    const data = [_]u8{ 0, 0, 0, HTTP2_FRAME_TYPE_SETTINGS, 0, 0, 0, 0, 0 };
    const frame = Frame.parse(&data);
    try std.testing.expect(frame != null);
    try std.testing.expect(frame.?.frame_type == HTTP2_FRAME_TYPE_SETTINGS);
    try std.testing.expect(frame.?.stream_id == 0);
}

test "Connection init" {
    var conn = Connection.init(std.testing.allocator);
    defer conn.deinit();
    try std.testing.expect(!conn.preface_received);
    try std.testing.expect(conn.streams.count() == 0);
}

fn expectHeader(headers: []const Header, idx: usize, name: []const u8, value: []const u8) !void {
    try std.testing.expect(idx < headers.len);
    try std.testing.expectEqualStrings(name, headers[idx].name);
    try std.testing.expectEqualStrings(value, headers[idx].value);
}

test "HPACK decode RFC 7541 C.4 request sequence with Huffman + dynamic table" {
    const a = std.testing.allocator;
    var dec = Decoder.init(a);
    defer dec.deinit();

    // C.4.1 — first request, Huffman-coded :authority.
    {
        const block = [_]u8{ 0x82, 0x86, 0x84, 0x41, 0x8c, 0xf1, 0xe3, 0xc2, 0xe5, 0xf2, 0x3a, 0x6b, 0xa0, 0xab, 0x90, 0xf4, 0xff };
        var out: std.ArrayList(Header) = .empty;
        defer out.deinit(a);
        try dec.decode(&block, &out);
        try std.testing.expectEqual(@as(usize, 4), out.items.len);
        try expectHeader(out.items, 0, ":method", "GET");
        try expectHeader(out.items, 1, ":scheme", "http");
        try expectHeader(out.items, 2, ":path", "/");
        try expectHeader(out.items, 3, ":authority", "www.example.com");
        // Dynamic table now holds :authority: www.example.com (32+10+15 = 57).
        try std.testing.expectEqual(@as(u32, 57), dec.table_size);
    }

    // C.4.2 — second request references the dynamic entry (index 62) and
    // adds cache-control: no-cache. This is exactly the cross-request
    // indexing that the old no-op dynamic table dropped on the floor.
    {
        const block = [_]u8{ 0x82, 0x86, 0x84, 0xbe, 0x58, 0x86, 0xa8, 0xeb, 0x10, 0x64, 0x9c, 0xbf };
        var out: std.ArrayList(Header) = .empty;
        defer out.deinit(a);
        try dec.decode(&block, &out);
        try std.testing.expectEqual(@as(usize, 5), out.items.len);
        try expectHeader(out.items, 3, ":authority", "www.example.com");
        try expectHeader(out.items, 4, "cache-control", "no-cache");
    }

    // C.4.3 — third request, Huffman literal custom-key: custom-value
    // (with incremental indexing). `bf` references :authority at dynamic
    // index 63 (cache-control was inserted in front of it in C.4.2).
    {
        const block = [_]u8{ 0x82, 0x87, 0x85, 0xbf, 0x40, 0x88, 0x25, 0xa8, 0x49, 0xe9, 0x5b, 0xa9, 0x7d, 0x7f } ++
            [_]u8{ 0x89, 0x25, 0xa8, 0x49, 0xe9, 0x5b, 0xb8, 0xe8, 0xb4, 0xbf };
        var out: std.ArrayList(Header) = .empty;
        defer out.deinit(a);
        try dec.decode(&block, &out);
        try expectHeader(out.items, 3, ":authority", "www.example.com");
        try expectHeader(out.items, out.items.len - 1, "custom-key", "custom-value");
    }
}

test "HPACK decode rejects out-of-range index" {
    const a = std.testing.allocator;
    var dec = Decoder.init(a);
    defer dec.deinit();
    var out: std.ArrayList(Header) = .empty;
    defer out.deinit(a);
    // Index 99 with an empty dynamic table → CompressionError, not a crash.
    const block = [_]u8{ 0x80 | 99 };
    try std.testing.expectError(error.CompressionError, dec.decode(&block, &out));
}

fn buildFrame(buf: []u8, ftype: u8, flags: u8, stream: u31, payload: []const u8) []u8 {
    buf[0] = @truncate(payload.len >> 16);
    buf[1] = @truncate(payload.len >> 8);
    buf[2] = @truncate(payload.len);
    buf[3] = ftype;
    buf[4] = flags;
    std.mem.writeInt(u32, buf[5..9], @as(u32, stream), .big);
    @memcpy(buf[9 .. 9 + payload.len], payload);
    return buf[0 .. 9 + payload.len];
}

test "SETTINGS with payload not a multiple of 6 is a FrameSizeError" {
    var conn = Connection.init(std.testing.allocator);
    defer conn.deinit();
    var buf: [32]u8 = undefined;
    const f = buildFrame(&buf, HTTP2_FRAME_TYPE_SETTINGS, 0, 0, &[_]u8{ 0, 1, 2 });
    try std.testing.expectError(error.FrameSizeError, conn.processFrame(f));
}

test "WINDOW_UPDATE that overflows the window is a FlowControlError" {
    var conn = Connection.init(std.testing.allocator);
    defer conn.deinit();
    conn.connection_window = HTTP2_MAX_WINDOW; // already at the ceiling
    var buf: [32]u8 = undefined;
    var inc: [4]u8 = undefined;
    std.mem.writeInt(u32, &inc, 1, .big);
    const f = buildFrame(&buf, HTTP2_FRAME_TYPE_WINDOW_UPDATE, 0, 0, &inc);
    try std.testing.expectError(error.FlowControlError, conn.processFrame(f));
}

test "MAX_CONCURRENT_STREAMS is enforced with RST_STREAM REFUSED_STREAM" {
    var conn = Connection.init(std.testing.allocator);
    defer conn.deinit();
    conn.settings.max_concurrent_streams = 1;
    var buf: [32]u8 = undefined;

    // Stream 1: opens (no END_STREAM) → active_stream_count == 1.
    {
        const f = buildFrame(&buf, HTTP2_FRAME_TYPE_HEADERS, HTTP2_FLAG_END_HEADERS, 1, &[_]u8{0x82});
        var r = (try conn.processFrame(f)).?;
        if (r.headers) |*h| h.deinit(conn.allocator);
        try std.testing.expectEqual(@as(u32, 1), conn.active_stream_count);
    }
    // Stream 3: would be the 2nd concurrent open stream → refused.
    {
        const f = buildFrame(&buf, HTTP2_FRAME_TYPE_HEADERS, HTTP2_FLAG_END_HEADERS, 3, &[_]u8{0x82});
        const r = (try conn.processFrame(f)).?;
        try std.testing.expectEqual(@as(u31, 3), r.rst_stream);
        try std.testing.expectEqual(HTTP2_ERROR_REFUSED_STREAM, r.rst_error);
        try std.testing.expect(r.headers == null);
    }
}

test "HEADERS + CONTINUATION reassemble into one header block" {
    var conn = Connection.init(std.testing.allocator);
    defer conn.deinit();
    var buf: [32]u8 = undefined;

    // HEADERS (no END_HEADERS) carrying the first indexed field.
    const h = buildFrame(&buf, HTTP2_FRAME_TYPE_HEADERS, HTTP2_FLAG_END_STREAM, 1, &[_]u8{0x82});
    try std.testing.expect((try conn.processFrame(h)) == null);
    try std.testing.expect(conn.expecting_continuation);

    // A non-CONTINUATION frame here must be rejected.
    var buf2: [32]u8 = undefined;
    const bad = buildFrame(&buf2, HTTP2_FRAME_TYPE_DATA, 0, 1, &[_]u8{0x00});
    try std.testing.expectError(error.ProtocolError, conn.processFrame(bad));

    // CONTINUATION with END_HEADERS carrying the second indexed field.
    const c = buildFrame(&buf2, HTTP2_FRAME_TYPE_CONTINUATION, HTTP2_FLAG_END_HEADERS, 1, &[_]u8{0x86});
    var r = (try conn.processFrame(c)).?;
    defer if (r.headers) |*hh| hh.deinit(conn.allocator);
    try std.testing.expect(r.headers != null);
    try std.testing.expectEqual(@as(usize, 2), r.headers.?.items.len);
    try expectHeader(r.headers.?.items, 0, ":method", "GET");
    try expectHeader(r.headers.?.items, 1, ":scheme", "http");
    try std.testing.expect(!conn.expecting_continuation);
}

test "HPACK decode handles long (>=128 byte) literal value via integer continuation" {
    const a = std.testing.allocator;
    var dec = Decoder.init(a);
    defer dec.deinit();
    // Literal without indexing, new name "x" (len 1), value of 200 'a's,
    // length encoded as a 7-bit-prefix integer continuation (200 = 127 + 73).
    var block: std.ArrayList(u8) = .empty;
    defer block.deinit(a);
    try block.append(a, 0x00); // literal w/o indexing, name index 0
    try block.append(a, 0x01); // name length 1 (not huffman)
    try block.append(a, 'x');
    try block.append(a, 0x7f); // value length: prefix all-ones → continuation
    try block.append(a, 200 - 127); // 73
    try block.appendNTimes(a, 'a', 200);
    var out: std.ArrayList(Header) = .empty;
    defer out.deinit(a);
    try dec.decode(block.items, &out);
    try std.testing.expectEqual(@as(usize, 1), out.items.len);
    try std.testing.expectEqualStrings("x", out.items[0].name);
    try std.testing.expectEqual(@as(usize, 200), out.items[0].value.len);
}