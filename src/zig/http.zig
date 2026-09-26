// HTTP/1.1 request parser.
//
// Design:
//   - Caller owns the read buffer; the parser only stores slices into it.
//   - Caller provides the headers backing array, sized to `max_headers`.
//   - Zero allocations per request: the only "memory" used is the caller's
//     stack-allocated buffers.
//   - Single forward pass. Returns `error.Incomplete` so the caller can
//     `read(2)` more bytes and re-attempt with the same buffer.
//
// Out of scope for v0.2 (lands in later milestones):
//   - chunked Transfer-Encoding (decode body chunks)
//   - HTTP/2 / HTTP/3
//   - request validation beyond what's needed to safely build an ASGI scope

const std = @import("std");

pub const ParseError = error{
    /// Need more bytes — caller should read more and retry.
    Incomplete,
    BadRequestLine,
    BadHeader,
    HeadersTooLarge,
    UnsupportedVersion,
    InvalidContentLength,
};

/// v1.8: compressed Header. Was: two `[]const u8` slices = 32 B per
/// Header (16 B per fat pointer). Each pool Buffer holds
/// `[max_headers]Header` = 32 × 32 B = 1 KiB. New: four `u16`s into
/// `Buffer.data` = 8 B per Header, 256 B per Buffer. Saves 768 B per
/// active in-flight request — at 1024 max concurrent ~770 KiB peak.
/// u16 caps each header at 64 KiB which exceeds the read-buffer
/// ceiling anyway, so no real-world request loses fidelity.
pub const Header = struct {
    name_off: u16,
    name_len: u16,
    value_off: u16,
    value_len: u16,

    pub inline fn nameSlice(self: Header, data: []const u8) []const u8 {
        return data[self.name_off..][0..self.name_len];
    }
    pub inline fn valueSlice(self: Header, data: []const u8) []const u8 {
        return data[self.value_off..][0..self.value_len];
    }
};

pub const Request = struct {
    /// v1.8: backing buffer. All `*_off` fields below — `method`,
    /// `target`, plus every `Header.name_off` / `value_off` in
    /// `headers` — index into this slice. Stored once on the
    /// Request rather than threaded through every accessor call.
    data: []const u8,
    /// Request method (`GET`, `POST`, …). Compressed to offset+len
    /// into `data` for parity with the Header layout.
    method_off: u16,
    method_len: u16,
    /// Request-target (path + optional query). Untouched: no decoding.
    target_off: u16,
    target_len: u16,
    /// HTTP/1.x minor version (0 or 1).
    version_minor: u8,
    /// Slice of the caller-provided headers array. Each Header carries
    /// `(name_off, name_len, value_off, value_len)` into `data`.
    headers: []const Header,
    /// Index in the read buffer where the body starts (just past \r\n\r\n).
    body_offset: usize,
    /// Parsed Content-Length, if present. Ignored when `is_chunked` is true
    /// (RFC 7230 says Transfer-Encoding wins over Content-Length).
    content_length: ?usize,
    /// True when Transfer-Encoding includes "chunked" (case-insensitive,
    /// any token in a comma-separated list).
    is_chunked: bool,
    /// v1.12: the request-target was absolute-form with an empty path
    /// (`GET http://host?x=1`). RFC 3986 §6.2.3 says an empty path is
    /// equivalent to "/", but the parser addresses its slices by
    /// offset+len into `data` and there is no "/" to point at, so the
    /// substitution is recorded here instead. Set only on that path;
    /// origin-form targets never set it.
    target_is_root: bool,

    pub inline fn method(self: Request) []const u8 {
        return self.data[self.method_off..][0..self.method_len];
    }
    /// Path + optional query. For the absolute-form empty-path case this
    /// is "/", the form an origin server must route on.
    pub inline fn target(self: Request) []const u8 {
        if (self.target_is_root) return "/";
        return self.data[self.target_off..][0..self.target_len];
    }
    /// The bytes that followed the authority in an absolute-form target,
    /// before the "/" substitution — so `http://host?a=1` yields `?a=1`
    /// here. Only meaningful when `target_is_root`; it exists so the
    /// query string survives the substitution, which `target()` alone
    /// cannot carry.
    pub inline fn targetRemainder(self: Request) []const u8 {
        return self.data[self.target_off..][0..self.target_len];
    }

    /// Returns the value of a header by name (case-insensitive), or null if
    /// not present. If the header appears more than once only the first
    /// occurrence is returned.
    pub fn header(self: Request, name: []const u8) ?[]const u8 {
        for (self.headers) |h| {
            if (std.ascii.eqlIgnoreCase(h.nameSlice(self.data), name))
                return h.valueSlice(self.data);
        }
        return null;
    }

    /// True if the request is a valid RFC 6455 WebSocket upgrade attempt:
    /// HTTP/1.1 GET with the four required handshake headers (Upgrade,
    /// Connection, Sec-WebSocket-Key, Sec-WebSocket-Version: 13). Saltare
    /// only speaks WS version 13.
    pub fn isWebSocketUpgrade(self: Request) bool {
        if (self.version_minor != 1) return false;
        if (!std.ascii.eqlIgnoreCase(self.method(), "GET")) return false;

        const upgrade = self.header("upgrade") orelse return false;
        if (!connectionTokenPresent(upgrade, "websocket")) return false;

        const conn = self.header("connection") orelse return false;
        if (!connectionTokenPresent(conn, "upgrade")) return false;

        if (self.header("sec-websocket-key") == null) return false;

        const ver = self.header("sec-websocket-version") orelse return false;
        const ver_trimmed = std.mem.trim(u8, ver, " \t");
        if (!std.mem.eql(u8, ver_trimmed, "13")) return false;

        return true;
    }

    /// Whether the connection should be kept alive after this request.
    /// RFC 7230 §6.3:
    ///   - HTTP/1.1: persistent unless `Connection: close` is present.
    ///   - HTTP/1.0: close unless `Connection: keep-alive` is present.
    pub fn wantsKeepAlive(self: Request) bool {
        const conn_value = self.header("connection");
        return switch (self.version_minor) {
            1 => if (conn_value) |v| !connectionTokenPresent(v, "close") else true,
            0 => if (conn_value) |v| connectionTokenPresent(v, "keep-alive") else false,
            else => false,
        };
    }
};

/// Treat a Connection header value as a comma-separated token list and
/// return true if `needle` appears (ASCII case-insensitive, OWS-trimmed).
fn connectionTokenPresent(value: []const u8, needle: []const u8) bool {
    var iter = std.mem.splitScalar(u8, value, ',');
    while (iter.next()) |raw| {
        const trimmed = std.mem.trim(u8, raw, " \t");
        if (std.ascii.eqlIgnoreCase(trimmed, needle)) return true;
    }
    return false;
}

// 32 covers virtually every real-world request (typical browsers send
// 12–18 headers; even a heavily-cookied / JWT-laden API request rarely
// exceeds 24). Lowered from 64 in v1.1 — saves ~1 KiB per active pool
// buffer because the parsed-headers array lives inside the buffer
// struct (see `pool.zig`). Requests with more than this many headers
// still get a clean 431 via the parser's "too many headers" path.
pub const max_headers = 32;

/// Percent-decode `src` into `dst`. Returns the number of decoded bytes
/// written. `dst` must be at least `src.len` bytes long (decoded length is
/// always ≤ source length). Invalid `%XX` sequences (non-hex, truncated)
/// are passed through verbatim so we never reject a request whose path the
/// user app might still understand. v1.3 addition — replaces the
/// `urllib.parse.unquote_to_bytes` call in `_dispatcher.py`, dropping the
/// urllib import entirely.
pub fn urlDecode(src: []const u8, dst: []u8) usize {
    std.debug.assert(dst.len >= src.len);
    var w: usize = 0;
    var i: usize = 0;
    while (i < src.len) {
        const b = src[i];
        if (b == '%' and i + 2 < src.len) {
            const hi = std.fmt.charToDigit(src[i + 1], 16) catch {
                dst[w] = b;
                w += 1;
                i += 1;
                continue;
            };
            const lo = std.fmt.charToDigit(src[i + 2], 16) catch {
                dst[w] = b;
                w += 1;
                i += 1;
                continue;
            };
            dst[w] = (hi << 4) | lo;
            w += 1;
            i += 3;
        } else {
            dst[w] = b;
            w += 1;
            i += 1;
        }
    }
    return w;
}

/// Fast pass: returns true if `s` contains any byte we'd actually need to
/// decode. Caller can short-circuit allocation when false.
pub inline fn needsUrlDecode(s: []const u8) bool {
    return std.mem.indexOfScalar(u8, s, '%') != null;
}

/// RFC 7230 §3.2.6 token character — header field-names are made of
/// these. Anything outside this set in a header name is a parse error
/// and we fail the whole request rather than risk header smuggling.
inline fn isTchar(b: u8) bool {
    return switch (b) {
        '0'...'9', 'A'...'Z', 'a'...'z' => true,
        '!', '#', '$', '%', '&', '\'', '*', '+', '-', '.', '^', '_', '`', '|', '~' => true,
        else => false,
    };
}

pub fn parse(buf: []const u8, headers_out: []Header) ParseError!Request {
    // v1.8: u16 offsets impose a 64 KiB ceiling on the head section.
    // The pool buffer's data slice (small 4 KiB / large 16 KiB) is
    // already well under that — we'd hit the implicit pool ceiling
    // long before u16 wraps. Guard anyway so a hypothetical large
    // pool grow doesn't silently truncate offsets.
    if (buf.len > std.math.maxInt(u16)) return error.HeadersTooLarge;

    // Locate the end of the head section. Without it the request is incomplete.
    const head_end = std.mem.indexOf(u8, buf, "\r\n\r\n") orelse return error.Incomplete;
    const head = buf[0..head_end];
    const body_offset = head_end + 4;

    // Request line: METHOD SP TARGET SP HTTP/1.x
    const line_end = std.mem.indexOf(u8, head, "\r\n") orelse head.len;
    const request_line = head[0..line_end];

    // Manually walk the request line so we can capture offsets
    // relative to `buf` (the parser's contract — header / target
    // offsets must be resolvable from the same backing slice).
    const sp1 = std.mem.indexOfScalar(u8, request_line, ' ') orelse return error.BadRequestLine;
    const sp2 = std.mem.indexOfScalarPos(u8, request_line, sp1 + 1, ' ') orelse return error.BadRequestLine;
    if (std.mem.indexOfScalarPos(u8, request_line, sp2 + 1, ' ') != null) return error.BadRequestLine;
    const method_off: u16 = 0;
    const method_len: u16 = @intCast(sp1);
    var target_off: u16 = @intCast(sp1 + 1);
    var target_len: u16 = @intCast(sp2 - (sp1 + 1));
    var target_is_root = false;

    // RFC 7230 §5.3.2 — absolute-form. A client may send
    // `GET http://example.com/path?q=1`, and "an origin server MUST
    // ignore the scheme and authority" and route on what remains.
    //
    // v1.12: this was not handled, so an absolute-form target was handed
    // to the router verbatim and every such request 404'd. It is rare
    // from browsers but not exotic: forward proxies use it towards the
    // next hop, and some health checkers and load balancers address
    // origin servers this way.
    if (absoluteFormPath(request_line[sp1 + 1 .. sp2])) |abs| {
        target_off = @intCast(sp1 + 1 + abs.off);
        target_len = @intCast(abs.len);
        target_is_root = abs.path_empty;
    }
    const version = request_line[sp2 + 1 ..];
    // `target_is_root` means the target was absolute-form with an empty
    // path, whose effective value is "/" — not an empty target.
    if (method_len == 0 or (target_len == 0 and !target_is_root)) {
        return error.BadRequestLine;
    }

    if (version.len != 8 or !std.mem.startsWith(u8, version, "HTTP/1.")) {
        return error.UnsupportedVersion;
    }
    const version_minor: u8 = switch (version[7]) {
        '0' => 0,
        '1' => 1,
        else => return error.UnsupportedVersion,
    };

    // Headers
    var header_count: usize = 0;
    var content_length: ?usize = null;
    var is_chunked: bool = false;
    var pos: usize = if (line_end < head.len) line_end + 2 else head.len;

    while (pos < head.len) {
        const eol = std.mem.indexOfPos(u8, head, pos, "\r\n") orelse head.len;
        const line = head[pos..eol];
        if (line.len == 0) break; // shouldn't happen: \r\n\r\n already split off

        const colon = std.mem.indexOfScalar(u8, line, ':') orelse return error.BadHeader;
        if (colon == 0) return error.BadHeader;
        // RFC 7230 §3.2.6 — header names are `tchar*`, i.e. ASCII
        // alphanumerics plus the punctuation set
        // `!#$%&'*+-.^_` `|~`. Reject any byte outside that set so a
        // malformed `Header\0Smuggled: x` can't slip through to the
        // user app and a downstream proxy reading it back as two
        // separate headers.
        for (line[0..colon]) |b| {
            if (!isTchar(b)) return error.BadHeader;
        }

        // Trim OWS (space + tab) from both ends of the value.
        var v_start = colon + 1;
        while (v_start < line.len and (line[v_start] == ' ' or line[v_start] == '\t')) {
            v_start += 1;
        }
        var v_end = line.len;
        while (v_end > v_start and (line[v_end - 1] == ' ' or line[v_end - 1] == '\t')) {
            v_end -= 1;
        }
        const name_off: u16 = @intCast(pos);
        const name_len: u16 = @intCast(colon);
        const value_off: u16 = @intCast(pos + v_start);
        const value_len: u16 = @intCast(v_end - v_start);

        if (header_count >= headers_out.len) return error.HeadersTooLarge;
        headers_out[header_count] = .{
            .name_off = name_off,
            .name_len = name_len,
            .value_off = value_off,
            .value_len = value_len,
        };
        header_count += 1;

        const name = buf[name_off..][0..name_len];
        const value = buf[value_off..][0..value_len];
        if (std.ascii.eqlIgnoreCase(name, "content-length")) {
            content_length = std.fmt.parseInt(usize, value, 10) catch return error.InvalidContentLength;
        } else if (std.ascii.eqlIgnoreCase(name, "transfer-encoding")) {
            if (transferEncodingIsChunked(value)) is_chunked = true;
        }

        pos = eol + 2;
    }

    return Request{
        .data = buf,
        .method_off = method_off,
        .method_len = method_len,
        .target_off = target_off,
        .target_len = target_len,
        .version_minor = version_minor,
        .headers = headers_out[0..header_count],
        .body_offset = body_offset,
        // RFC 7230 §3.3.3: if both Content-Length and Transfer-Encoding are
        // present, Transfer-Encoding wins; we surface that by clearing CL.
        .content_length = if (is_chunked) null else content_length,
        .is_chunked = is_chunked,
        .target_is_root = target_is_root,
    };
}

/// RFC 7230 §5.3.2 absolute-form: locate the path+query inside
/// `scheme://authority/path?query`.
///
/// Returns null when the target is already origin-form (`/path`, `*`) or
/// when it merely *contains* "://" somewhere that is not a scheme — a
/// path segment is allowed to hold a colon, and a slash before the "://"
/// means it is a real path, not a scheme separator.
///
/// `off`/`len` index into `target` and cover the path *and* the query, so
/// the query survives even when `path_empty` is set. `path_empty` reports
/// the RFC 3986 §6.2.3 case (`http://host`, `http://host?a=1`), where the
/// effective path is "/" and the parser has to substitute it.
fn absoluteFormPath(target: []const u8) ?struct { off: usize, len: usize, path_empty: bool } {
    const sep = std.mem.indexOf(u8, target, "://") orelse return null;
    if (sep == 0) return null;
    const scheme = target[0..sep];
    if (std.mem.indexOfScalar(u8, scheme, '/') != null) return null;
    for (scheme) |ch| {
        if (!std.ascii.isAlphanumeric(ch) and ch != '+' and ch != '-' and ch != '.') {
            return null;
        }
    }
    // Skip the authority: it ends at the first '/', '?' or the end.
    var i = sep + 3;
    while (i < target.len and target[i] != '/' and target[i] != '?') : (i += 1) {}
    return .{
        .off = i,
        .len = target.len - i,
        .path_empty = i >= target.len or target[i] == '?',
    };
}

/// True if the Transfer-Encoding header value lists "chunked" as a token.
/// Allows `chunked`, `gzip, chunked`, etc. — saltare won't decompress, just
/// dechunk; a value that's chunked + gzip will deliver gzipped bytes to the
/// app, which must know how to decompress.
fn transferEncodingIsChunked(value: []const u8) bool {
    var iter = std.mem.splitScalar(u8, value, ',');
    while (iter.next()) |raw| {
        const trimmed = std.mem.trim(u8, raw, " \t");
        if (std.ascii.eqlIgnoreCase(trimmed, "chunked")) return true;
    }
    return false;
}

// ---------------------------------------------------------------------------
// Chunked Transfer-Encoding decoder (request bodies).
//
// In-place decoder: reads raw chunked bytes from a contiguous buffer and
// rewrites the decoded bytes onto the same buffer. Because chunked encoding
// always adds overhead (size lines + CRLFs) the decoded prefix is always at
// or behind the raw cursor, so a forward copy is safe.
//
// State is caller-owned so decoding can resume across multiple read calls
// without buffering the whole request first.

pub const ChunkState = struct {
    phase: Phase,
    chunk_remaining: usize,

    pub const Phase = enum { size, data, data_term, end_crlf, done };

    pub fn init() ChunkState {
        return .{ .phase = .size, .chunk_remaining = 0 };
    }
};

pub const ChunkResult = enum { needs_more, done, invalid };

/// Decode chunked bytes in-place. Reads raw bytes from
/// `body_buf[consumed.*..body_buf_len]` and writes decoded bytes to
/// `body_buf[..decoded.*]`. Trailers (headers between the 0-chunk and the
/// final CRLF) are not supported in v0.8: a 0-chunk followed by anything
/// other than `\r\n` returns `.invalid`.
pub fn decodeChunkedInPlace(
    body_buf: []u8,
    body_buf_len: usize,
    state: *ChunkState,
    consumed: *usize,
    decoded: *usize,
) ChunkResult {
    while (true) {
        switch (state.phase) {
            .done => return .done,
            .size => {
                const available = body_buf[consumed.*..body_buf_len];
                const eol = std.mem.indexOf(u8, available, "\r\n") orelse return .needs_more;
                const size_str = available[0..eol];
                if (size_str.len == 0) return .invalid;

                // Strip optional chunk extensions ("size;ext=value").
                const semi = std.mem.indexOfScalar(u8, size_str, ';') orelse size_str.len;
                const hex = std.mem.trim(u8, size_str[0..semi], " \t");
                if (hex.len == 0) return .invalid;
                const size = std.fmt.parseInt(usize, hex, 16) catch return .invalid;

                state.chunk_remaining = size;
                consumed.* += eol + 2;
                state.phase = if (size == 0) .end_crlf else .data;
            },
            .data => {
                if (state.chunk_remaining == 0) {
                    state.phase = .data_term;
                    continue;
                }
                const available = body_buf_len - consumed.*;
                if (available == 0) return .needs_more;
                const take = @min(state.chunk_remaining, available);

                // Forward copy: decoded.* <= consumed.* always.
                var i: usize = 0;
                while (i < take) : (i += 1) {
                    body_buf[decoded.* + i] = body_buf[consumed.* + i];
                }
                consumed.* += take;
                decoded.* += take;
                state.chunk_remaining -= take;
                if (state.chunk_remaining == 0) state.phase = .data_term;
            },
            .data_term => {
                if (body_buf_len - consumed.* < 2) return .needs_more;
                if (body_buf[consumed.*] != '\r' or body_buf[consumed.* + 1] != '\n') {
                    return .invalid;
                }
                consumed.* += 2;
                state.phase = .size;
            },
            .end_crlf => {
                if (body_buf_len - consumed.* < 2) return .needs_more;
                if (body_buf[consumed.*] != '\r' or body_buf[consumed.* + 1] != '\n') {
                    return .invalid;
                }
                consumed.* += 2;
                state.phase = .done;
                return .done;
            },
        }
    }
}

// ---------------------------------------------------------------------------
// Tests — run with `zig test src/zig/http.zig` if Zig is on the host. Inside
// the Docker pipeline these don't execute (we don't invoke `zig test`), but
// they document expected behaviour and are a quick sanity check during
// local iteration.

const testing = std.testing;

test "parse minimal GET" {
    const buf = "GET / HTTP/1.1\r\nHost: example.com\r\n\r\n";
    var headers: [max_headers]Header = undefined;
    const req = try parse(buf, &headers);
    try testing.expectEqualStrings("GET", req.method());
    try testing.expectEqualStrings("/", req.target());
    try testing.expectEqual(@as(u8, 1), req.version_minor);
    try testing.expectEqual(@as(usize, 1), req.headers.len);
    try testing.expectEqualStrings("Host", req.headers[0].nameSlice(req.data));
    try testing.expectEqualStrings("example.com", req.headers[0].valueSlice(req.data));
    try testing.expectEqual(@as(?usize, null), req.content_length);
}

test "parse POST with Content-Length and body" {
    const buf = "POST /submit?id=7 HTTP/1.1\r\n" ++
        "Host: api\r\n" ++
        "Content-Length: 5\r\n" ++
        "\r\n" ++
        "hello";
    var headers: [max_headers]Header = undefined;
    const req = try parse(buf, &headers);
    try testing.expectEqualStrings("POST", req.method());
    try testing.expectEqualStrings("/submit?id=7", req.target());
    try testing.expectEqual(@as(?usize, 5), req.content_length);
    try testing.expectEqualStrings("hello", buf[req.body_offset..]);
}

test "incomplete returns error.Incomplete" {
    const buf = "GET / HTTP/1.1\r\nHost: x\r\n";
    var headers: [max_headers]Header = undefined;
    try testing.expectError(error.Incomplete, parse(buf, &headers));
}

test "case-insensitive Content-Length detection" {
    const buf = "POST / HTTP/1.1\r\ncontent-length: 0\r\n\r\n";
    var headers: [max_headers]Header = undefined;
    const req = try parse(buf, &headers);
    try testing.expectEqual(@as(?usize, 0), req.content_length);
}

test "OWS around header values is trimmed" {
    const buf = "GET / HTTP/1.1\r\nX-Foo:   bar\t \r\n\r\n";
    var headers: [max_headers]Header = undefined;
    const req = try parse(buf, &headers);
    try testing.expectEqualStrings("bar", req.headers[0].valueSlice(req.data));
}

test "rejects bogus version" {
    const buf = "GET / HTTP/9.9\r\n\r\n";
    var headers: [max_headers]Header = undefined;
    try testing.expectError(error.UnsupportedVersion, parse(buf, &headers));
}

test "rejects header without colon" {
    const buf = "GET / HTTP/1.1\r\nNoColonHere\r\n\r\n";
    var headers: [max_headers]Header = undefined;
    try testing.expectError(error.BadHeader, parse(buf, &headers));
}

test "wantsKeepAlive: HTTP/1.1 default is keep-alive" {
    const buf = "GET / HTTP/1.1\r\nHost: x\r\n\r\n";
    var headers: [max_headers]Header = undefined;
    const req = try parse(buf, &headers);
    try testing.expect(req.wantsKeepAlive());
}

test "wantsKeepAlive: HTTP/1.1 with Connection: close" {
    const buf = "GET / HTTP/1.1\r\nConnection: close\r\n\r\n";
    var headers: [max_headers]Header = undefined;
    const req = try parse(buf, &headers);
    try testing.expect(!req.wantsKeepAlive());
}

test "wantsKeepAlive: HTTP/1.0 default is close" {
    const buf = "GET / HTTP/1.0\r\nHost: x\r\n\r\n";
    var headers: [max_headers]Header = undefined;
    const req = try parse(buf, &headers);
    try testing.expect(!req.wantsKeepAlive());
}

test "wantsKeepAlive: HTTP/1.0 with Connection: Keep-Alive" {
    const buf = "GET / HTTP/1.0\r\nConnection: Keep-Alive\r\n\r\n";
    var headers: [max_headers]Header = undefined;
    const req = try parse(buf, &headers);
    try testing.expect(req.wantsKeepAlive());
}

test "wantsKeepAlive: token list with close" {
    const buf = "GET / HTTP/1.1\r\nConnection: keep-alive, close\r\n\r\n";
    var headers: [max_headers]Header = undefined;
    const req = try parse(buf, &headers);
    try testing.expect(!req.wantsKeepAlive());
}

test "parse: detects Transfer-Encoding: chunked" {
    const buf = "POST / HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\n";
    var headers: [max_headers]Header = undefined;
    const req = try parse(buf, &headers);
    try testing.expect(req.is_chunked);
    try testing.expectEqual(@as(?usize, null), req.content_length);
}

test "parse: chunked overrides Content-Length" {
    const buf = "POST / HTTP/1.1\r\nContent-Length: 99\r\nTransfer-Encoding: chunked\r\n\r\n";
    var headers: [max_headers]Header = undefined;
    const req = try parse(buf, &headers);
    try testing.expect(req.is_chunked);
    try testing.expectEqual(@as(?usize, null), req.content_length);
}

test "decodeChunkedInPlace: simple two-chunk body" {
    var buf = "5\r\nhello\r\n6\r\n world\r\n0\r\n\r\n".*;
    var state = ChunkState.init();
    var consumed: usize = 0;
    var decoded: usize = 0;
    const result = decodeChunkedInPlace(&buf, buf.len, &state, &consumed, &decoded);
    try testing.expectEqual(ChunkResult.done, result);
    try testing.expectEqualStrings("hello world", buf[0..decoded]);
}

test "decodeChunkedInPlace: empty body (just 0-chunk)" {
    var buf = "0\r\n\r\n".*;
    var state = ChunkState.init();
    var consumed: usize = 0;
    var decoded: usize = 0;
    const result = decodeChunkedInPlace(&buf, buf.len, &state, &consumed, &decoded);
    try testing.expectEqual(ChunkResult.done, result);
    try testing.expectEqual(@as(usize, 0), decoded);
}

test "decodeChunkedInPlace: resumable across reads" {
    // Wire bytes, split mid-body so the decoder has to resume:
    //   "5\r\nhello\r\n"  = 11   (first chunk complete)
    //   "6\r\n "          =  3   -> 14 available on the first read
    //   "world\r\n"       =  7
    //   "0\r\n\r\n"       =  5   -> 26 available on the second read
    const first_read = 14;
    const total = 26;
    var buf: [64]u8 = undefined;
    @memcpy(buf[0..first_read], "5\r\nhello\r\n6\r\n ");
    var state = ChunkState.init();
    var consumed: usize = 0;
    var decoded: usize = 0;

    // Only the first 14 bytes are available; we should be told to wait.
    var result = decodeChunkedInPlace(&buf, first_read, &state, &consumed, &decoded);
    try testing.expectEqual(ChunkResult.needs_more, result);

    // Append the rest and resume.
    @memcpy(buf[first_read..total], "world\r\n0\r\n\r\n");
    result = decodeChunkedInPlace(&buf, total, &state, &consumed, &decoded);
    try testing.expectEqual(ChunkResult.done, result);
    try testing.expectEqualStrings("hello world", buf[0..decoded]);
}

test "decodeChunkedInPlace: rejects invalid hex" {
    var buf = "zz\r\n\r\n".*;
    var state = ChunkState.init();
    var consumed: usize = 0;
    var decoded: usize = 0;
    const result = decodeChunkedInPlace(&buf, buf.len, &state, &consumed, &decoded);
    try testing.expectEqual(ChunkResult.invalid, result);
}

// ---------------------------------------------------------------------------
// RFC 7230 §5.3.2 absolute-form
// ---------------------------------------------------------------------------

test "parse: origin-form target is untouched" {
    var buf: [64]Header = undefined;
    const r = try parse("GET /path?q=1 HTTP/1.1\r\nHost: h\r\n\r\n", &buf);
    try testing.expectEqualStrings("/path?q=1", r.target());
    try testing.expect(!r.target_is_root);
}

test "parse: absolute-form strips scheme and authority" {
    var buf: [64]Header = undefined;
    const r = try parse("GET http://example.com/path?q=1 HTTP/1.1\r\nHost: h\r\n\r\n", &buf);
    try testing.expectEqualStrings("/path?q=1", r.target());
    try testing.expect(!r.target_is_root);
}

test "parse: absolute-form with a port in the authority" {
    var buf: [64]Header = undefined;
    const r = try parse("GET http://127.0.0.1:8000/x HTTP/1.1\r\nHost: h\r\n\r\n", &buf);
    try testing.expectEqualStrings("/x", r.target());
}

test "parse: absolute-form with an https scheme" {
    var buf: [64]Header = undefined;
    const r = try parse("GET https://example.com/secure HTTP/1.1\r\nHost: h\r\n\r\n", &buf);
    try testing.expectEqualStrings("/secure", r.target());
}

test "parse: absolute-form with an empty path yields root" {
    var buf: [64]Header = undefined;
    const r = try parse("GET http://example.com HTTP/1.1\r\nHost: h\r\n\r\n", &buf);
    try testing.expectEqualStrings("/", r.target());
    try testing.expect(r.target_is_root);
}

test "parse: absolute-form with an empty path and a query" {
    // RFC 3986 §6.2.3: an empty path is "/", so the query still routes.
    var buf: [64]Header = undefined;
    const r = try parse("GET http://example.com?a=1 HTTP/1.1\r\nHost: h\r\n\r\n", &buf);
    try testing.expectEqualStrings("/", r.target());
    try testing.expectEqualStrings("?a=1", r.targetRemainder());
    try testing.expect(r.target_is_root);
}

test "parse: absolute-form trailing slash is preserved" {
    var buf: [64]Header = undefined;
    const r = try parse("GET http://example.com/ HTTP/1.1\r\nHost: h\r\n\r\n", &buf);
    try testing.expectEqualStrings("/", r.target());
}

test "parse: asterisk-form is left alone" {
    // `OPTIONS *` is its own form (RFC 7230 §5.3.4), not absolute-form.
    var buf: [64]Header = undefined;
    const r = try parse("OPTIONS * HTTP/1.1\r\nHost: h\r\n\r\n", &buf);
    try testing.expectEqualStrings("*", r.target());
    try testing.expect(!r.target_is_root);
}

test "parse: a path containing '://' is not mistaken for absolute-form" {
    // A colon in a path segment is legal, so a slash before the "://"
    // means the target is origin-form and must survive intact.
    var buf: [64]Header = undefined;
    const r = try parse("GET /redirect/http://example.com HTTP/1.1\r\nHost: h\r\n\r\n", &buf);
    try testing.expectEqualStrings("/redirect/http://example.com", r.target());
}

test "parse: a bare '://' with an empty scheme is not absolute-form" {
    var buf: [64]Header = undefined;
    const r = try parse("GET ://example.com/x HTTP/1.1\r\nHost: h\r\n\r\n", &buf);
    try testing.expectEqualStrings("://example.com/x", r.target());
}

test "parse: absolute-form method and body offsets are unaffected" {
    var buf: [64]Header = undefined;
    const r = try parse("POST http://example.com/p HTTP/1.1\r\nHost: h\r\nContent-Length: 5\r\n\r\nhello", &buf);
    try testing.expectEqualStrings("POST", r.method());
    try testing.expectEqualStrings("/p", r.target());
    try testing.expectEqual(@as(?usize, 5), r.content_length);
    try testing.expectEqualStrings("hello", r.data[r.body_offset..][0..5]);
    try testing.expectEqual(r.data.len, r.body_offset + 5);
}
