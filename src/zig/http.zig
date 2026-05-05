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

pub const Header = struct {
    name: []const u8,
    value: []const u8,
};

pub const Request = struct {
    method: []const u8,
    /// Request-target (path + optional query). Untouched: no decoding.
    target: []const u8,
    /// HTTP/1.x minor version (0 or 1).
    version_minor: u8,
    /// Slice of the caller-provided headers array. Names and values point
    /// into the read buffer; do not mutate it while reading these.
    headers: []const Header,
    /// Index in the read buffer where the body starts (just past \r\n\r\n).
    body_offset: usize,
    /// Parsed Content-Length, if present. `null` means no body framing.
    content_length: ?usize,

    /// Whether the connection should be kept alive after this request.
    /// RFC 7230 §6.3:
    ///   - HTTP/1.1: persistent unless `Connection: close` is present.
    ///   - HTTP/1.0: close unless `Connection: keep-alive` is present.
    pub fn wantsKeepAlive(self: Request) bool {
        var conn_value: ?[]const u8 = null;
        for (self.headers) |h| {
            if (std.ascii.eqlIgnoreCase(h.name, "connection")) {
                conn_value = h.value;
                break;
            }
        }

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

pub const max_headers = 64;

pub fn parse(buf: []const u8, headers_out: []Header) ParseError!Request {
    // Locate the end of the head section. Without it the request is incomplete.
    const head_end = std.mem.indexOf(u8, buf, "\r\n\r\n") orelse return error.Incomplete;
    const head = buf[0..head_end];
    const body_offset = head_end + 4;

    // Request line: METHOD SP TARGET SP HTTP/1.x
    const line_end = std.mem.indexOf(u8, head, "\r\n") orelse head.len;
    const request_line = head[0..line_end];

    var parts = std.mem.splitScalar(u8, request_line, ' ');
    const method = parts.next() orelse return error.BadRequestLine;
    const target = parts.next() orelse return error.BadRequestLine;
    const version = parts.next() orelse return error.BadRequestLine;
    if (parts.next() != null) return error.BadRequestLine;
    if (method.len == 0 or target.len == 0) return error.BadRequestLine;

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
    var pos: usize = if (line_end < head.len) line_end + 2 else head.len;

    while (pos < head.len) {
        const eol = std.mem.indexOfPos(u8, head, pos, "\r\n") orelse head.len;
        const line = head[pos..eol];
        if (line.len == 0) break; // shouldn't happen: \r\n\r\n already split off

        const colon = std.mem.indexOfScalar(u8, line, ':') orelse return error.BadHeader;
        if (colon == 0) return error.BadHeader;
        const name = line[0..colon];

        // Trim OWS (space + tab) from both ends of the value.
        var v_start = colon + 1;
        while (v_start < line.len and (line[v_start] == ' ' or line[v_start] == '\t')) {
            v_start += 1;
        }
        var v_end = line.len;
        while (v_end > v_start and (line[v_end - 1] == ' ' or line[v_end - 1] == '\t')) {
            v_end -= 1;
        }
        const value = line[v_start..v_end];

        if (header_count >= headers_out.len) return error.HeadersTooLarge;
        headers_out[header_count] = .{ .name = name, .value = value };
        header_count += 1;

        if (std.ascii.eqlIgnoreCase(name, "content-length")) {
            content_length = std.fmt.parseInt(usize, value, 10) catch return error.InvalidContentLength;
        }

        pos = eol + 2;
    }

    return Request{
        .method = method,
        .target = target,
        .version_minor = version_minor,
        .headers = headers_out[0..header_count],
        .body_offset = body_offset,
        .content_length = content_length,
    };
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
    try testing.expectEqualStrings("GET", req.method);
    try testing.expectEqualStrings("/", req.target);
    try testing.expectEqual(@as(u8, 1), req.version_minor);
    try testing.expectEqual(@as(usize, 1), req.headers.len);
    try testing.expectEqualStrings("Host", req.headers[0].name);
    try testing.expectEqualStrings("example.com", req.headers[0].value);
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
    try testing.expectEqualStrings("POST", req.method);
    try testing.expectEqualStrings("/submit?id=7", req.target);
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
    try testing.expectEqualStrings("bar", req.headers[0].value);
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
