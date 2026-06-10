// WebSocket (RFC 6455) frame parsing/writing + handshake helper.
//
// v0.10 scope:
//   - Single-frame text/binary messages (no continuation).
//   - Close frame with optional code/reason.
//   - Ping/pong: parsed but server-side response is left to the caller
//     (v0.10 doesn't auto-pong).
//   - Server-side only: incoming frames are masked, outgoing are not.
//   - No extensions (no permessage-deflate), no subprotocols.

const std = @import("std");

pub const Opcode = enum(u4) {
    continuation = 0x0,
    text = 0x1,
    binary = 0x2,
    close = 0x8,
    ping = 0x9,
    pong = 0xA,
    _,
};

pub const Header = struct {
    fin: bool,
    /// v1.6 RFC 7692 per-message-deflate. When negotiated, the
    /// server sets RSV1 on every compressed (text/binary) frame and
    /// the client sets it on its compressed frames. Always-zero on
    /// connections without the extension. Surfaced through the
    /// bridge so the dispatcher can decide whether to inflate the
    /// payload.
    rsv1: bool,
    opcode: Opcode,
    /// Raw 4-bit opcode value as read from the wire. v1.3 added so the
    /// fragmentation reassembler can distinguish "continuation"
    /// (opcode_raw == 0) from "binary"/"text" (1, 2) without going via
    /// the `Opcode` enum (whose `_` catch-all hides the distinction).
    opcode_raw: u4,
    masked: bool,
    payload_len: usize,
    mask_key: [4]u8,
    /// Number of bytes the header consumed from the input buffer. The
    /// payload starts at this offset.
    header_len: usize,
};

pub const ParseResult = union(enum) {
    needs_more,
    invalid,
    ok: Header,
};

/// Parse a WS frame header out of `buf`. Does NOT touch the payload.
pub fn parseHeader(buf: []const u8) ParseResult {
    if (buf.len < 2) return .needs_more;

    const b0 = buf[0];
    const b1 = buf[1];

    const fin = (b0 & 0x80) != 0;
    const rsv1 = (b0 & 0x40) != 0;
    const opcode_raw: u4 = @intCast(b0 & 0x0F);
    const masked = (b1 & 0x80) != 0;
    const len7: u7 = @intCast(b1 & 0x7F);

    // RFC 6455 §5.2: RSV2/RSV3 must be zero (no extension here defines them).
    // RSV1 is only valid when permessage-deflate was negotiated — that check
    // belongs to the caller, which knows the per-connection extension state.
    if ((b0 & 0x30) != 0) return .invalid;

    // RFC 6455 §5.5: control frames (opcode high bit set) MUST NOT be
    // fragmented and MUST carry <= 125 bytes, so they never use the 126/127
    // extended-length forms.
    const is_control = (opcode_raw & 0x08) != 0;
    if (is_control and (!fin or len7 > 125)) return .invalid;

    var idx: usize = 2;
    var payload_len: usize = len7;

    if (len7 == 126) {
        if (buf.len < idx + 2) return .needs_more;
        payload_len = (@as(usize, buf[idx]) << 8) | buf[idx + 1];
        idx += 2;
    } else if (len7 == 127) {
        if (buf.len < idx + 8) return .needs_more;
        // RFC 6455 §5.2: the most-significant bit of the 64-bit length MUST
        // be 0. Rejecting it also prevents `header_len + payload_len` from
        // overflowing usize in the caller's frame-size arithmetic.
        if (buf[idx] & 0x80 != 0) return .invalid;
        payload_len = 0;
        var i: usize = 0;
        while (i < 8) : (i += 1) {
            payload_len = (payload_len << 8) | buf[idx + i];
        }
        idx += 8;
    }

    var mask_key: [4]u8 = .{ 0, 0, 0, 0 };
    if (masked) {
        if (buf.len < idx + 4) return .needs_more;
        mask_key = .{ buf[idx], buf[idx + 1], buf[idx + 2], buf[idx + 3] };
        idx += 4;
    }

    return .{ .ok = .{
        .fin = fin,
        .rsv1 = rsv1,
        .opcode = @enumFromInt(opcode_raw),
        .opcode_raw = opcode_raw,
        .masked = masked,
        .payload_len = payload_len,
        .mask_key = mask_key,
        .header_len = idx,
    } };
}

/// Apply RFC 6455 unmasking in place (XOR each payload byte with the
/// rotating 4-byte key).
pub fn unmask(payload: []u8, key: [4]u8) void {
    for (payload, 0..) |byte, i| {
        payload[i] = byte ^ key[i % 4];
    }
}

/// Worst-case header size: 2 (base) + 8 (extended length) + 0 (server frames
/// are not masked). Server-side-only — clients must mask, but we never write
/// from a client perspective.
pub const max_server_header_size = 10;

/// Compute how many bytes a server frame with the given payload size will
/// occupy on the wire (header + payload).
pub fn frameSize(payload_len: usize) usize {
    const header = if (payload_len < 126)
        @as(usize, 2)
    else if (payload_len < 65536)
        @as(usize, 4)
    else
        @as(usize, 10);
    return header + payload_len;
}

/// Write an unmasked server frame into `buf`. Returns the slice of `buf`
/// containing the frame, or an error if the buffer is too small.
pub fn writeFrame(buf: []u8, opcode: Opcode, payload: []const u8) ![]u8 {
    const total = frameSize(payload.len);
    if (buf.len < total) return error.BufferTooSmall;

    // FIN=1, RSV1-3=0, opcode.
    buf[0] = 0x80 | @as(u8, @intFromEnum(opcode));

    var idx: usize = 0;
    if (payload.len < 126) {
        buf[1] = @intCast(payload.len);
        idx = 2;
    } else if (payload.len < 65536) {
        buf[1] = 126;
        buf[2] = @intCast((payload.len >> 8) & 0xFF);
        buf[3] = @intCast(payload.len & 0xFF);
        idx = 4;
    } else {
        buf[1] = 127;
        var i: usize = 0;
        while (i < 8) : (i += 1) {
            const shift: u6 = @intCast((7 - i) * 8);
            buf[2 + i] = @intCast((payload.len >> shift) & 0xFF);
        }
        idx = 10;
    }

    @memcpy(buf[idx .. idx + payload.len], payload);
    return buf[0..total];
}

// ---------------------------------------------------------------------------
// HTTP/1.1 → WebSocket handshake helper.

const WS_MAGIC = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11";

/// Compute the Sec-WebSocket-Accept value: base64(sha1(client_key || magic)).
/// Output buffer must be at least 28 bytes (the encoded length is constant).
pub fn computeAccept(client_key: []const u8, out: *[28]u8) []const u8 {
    var hasher = std.crypto.hash.Sha1.init(.{});
    hasher.update(client_key);
    hasher.update(WS_MAGIC);
    var digest: [20]u8 = undefined;
    hasher.final(&digest);

    const enc = std.base64.standard.Encoder;
    return enc.encode(out, &digest);
}

// ---------------------------------------------------------------------------
// Tests

const testing = std.testing;

test "parseHeader: short text frame from client" {
    // FIN+text, masked, len=5, mask=01020304, payload="hello" XOR mask
    var buf = [_]u8{ 0x81, 0x85, 0x01, 0x02, 0x03, 0x04, 'h' ^ 1, 'e' ^ 2, 'l' ^ 3, 'l' ^ 4, 'o' ^ 1 };
    const r = parseHeader(&buf);
    switch (r) {
        .ok => |h| {
            try testing.expect(h.fin);
            try testing.expectEqual(Opcode.text, h.opcode);
            try testing.expect(h.masked);
            try testing.expectEqual(@as(usize, 5), h.payload_len);
            try testing.expectEqual(@as(usize, 6), h.header_len);
            try testing.expectEqualSlices(u8, &.{ 1, 2, 3, 4 }, &h.mask_key);

            unmask(buf[h.header_len .. h.header_len + h.payload_len], h.mask_key);
            try testing.expectEqualStrings("hello", buf[h.header_len .. h.header_len + h.payload_len]);
        },
        else => try testing.expect(false),
    }
}

test "parseHeader: needs_more when truncated" {
    const buf = [_]u8{ 0x81, 0x85, 0x01, 0x02 }; // missing 2 bytes of mask
    const r = parseHeader(&buf);
    try testing.expectEqual(ParseResult.needs_more, r);
}

test "parseHeader: extended 16-bit length" {
    var buf: [10]u8 = .{ 0x82, 0xFE, 0x01, 0x00, 0x11, 0x22, 0x33, 0x44, 0, 0 };
    const r = parseHeader(&buf);
    switch (r) {
        .ok => |h| {
            try testing.expectEqual(Opcode.binary, h.opcode);
            try testing.expectEqual(@as(usize, 256), h.payload_len);
            try testing.expectEqual(@as(usize, 8), h.header_len);
        },
        else => try testing.expect(false),
    }
}

test "writeFrame: short text" {
    var buf: [16]u8 = undefined;
    const out = try writeFrame(&buf, .text, "hi");
    try testing.expectEqualSlices(u8, &.{ 0x81, 0x02, 'h', 'i' }, out);
}

test "writeFrame: 200-byte payload uses extended length" {
    const payload = [_]u8{'a'} ** 200;
    var buf: [256]u8 = undefined;
    const out = try writeFrame(&buf, .binary, &payload);
    try testing.expectEqual(@as(usize, 4 + 200), out.len);
    try testing.expectEqual(@as(u8, 0x82), out[0]);
    try testing.expectEqual(@as(u8, 126), out[1]);
    try testing.expectEqual(@as(u8, 0), out[2]);
    try testing.expectEqual(@as(u8, 200), out[3]);
}

test "parseHeader: rejects fragmented control frame (FIN=0 ping)" {
    // ping (0x9) with FIN=0, masked, len 0.
    const buf = [_]u8{ 0x09, 0x80, 0, 0, 0, 0 };
    try testing.expectEqual(ParseResult.invalid, parseHeader(&buf));
}

test "parseHeader: rejects oversized control frame (close with extended length)" {
    // close (0x8) with FIN=1 but len7 == 126 (extended) → invalid.
    const buf = [_]u8{ 0x88, 0xFE, 0x01, 0x00, 0, 0, 0, 0 };
    try testing.expectEqual(ParseResult.invalid, parseHeader(&buf));
}

test "parseHeader: rejects RSV2/RSV3 set" {
    // text frame with RSV2 (0x20) set, no extension → invalid.
    const buf = [_]u8{ 0xA1, 0x80, 0, 0, 0, 0 };
    try testing.expectEqual(ParseResult.invalid, parseHeader(&buf));
}

test "parseHeader: rejects 64-bit length with MSB set" {
    // binary frame, len7=127, first length byte has the high bit set.
    const buf = [_]u8{ 0x82, 0xFF, 0x80, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 };
    try testing.expectEqual(ParseResult.invalid, parseHeader(&buf));
}

test "computeAccept: RFC 6455 §1.3 example" {
    // From the RFC: key = "dGhlIHNhbXBsZSBub25jZQ==" → accept = "s3pPLMBiTxaQ9kYGzzhZRbK+xOo="
    var out: [28]u8 = undefined;
    const got = computeAccept("dGhlIHNhbXBsZSBub25jZQ==", &out);
    try testing.expectEqualStrings("s3pPLMBiTxaQ9kYGzzhZRbK+xOo=", got);
}
