// HPACK Encoder (RFC 7541).
//
// v1.10 rewrite. The previous encoder was incorrect in three ways and is
// not yet wired into the response path (HTTP/2 response framing is on the
// roadmap; v1.9 emitted HTTP/1.1-shaped bytes). The bugs it had:
//   * Indexed Header Fields were emitted without the 0x80 high bit (and the
//     ":status" path emitted a bare index), so the representation was a
//     malformed literal.
//   * Full static matches were emitted as `0x40 | idx` (literal with
//     incremental indexing) but then returned without the value string.
//   * String lengths were written as a single byte (`@intCast(value.len)`),
//     truncating/panicking for any value >= 128 bytes (Set-Cookie, Location,
//     CSP, ...).
//
// This implementation is stateless (static table only, no dynamic table —
// the prior dynamic table was a no-op). It emits:
//   * Indexed Header Field (0x80) for a full name+value static match.
//   * Literal without Indexing (0x00) otherwise, referencing a static name
//     index when available, with RFC 7541 §5.1 integer-encoded lengths and
//     optional Huffman (§5.2) when it is shorter.

const std = @import("std");
const h2_static = @import("h2_static.zig");
const huffman = @import("huffman.zig");

pub const EncoderError = error{OutOfMemory};

pub const Header = struct {
    name: []const u8,
    value: []const u8,
};

pub const Encoder = struct {
    pub fn encode(headers: []const Header, allocator: std.mem.Allocator) EncoderError![]u8 {
        var output: std.ArrayList(u8) = .empty;
        errdefer output.deinit(allocator);
        for (headers) |header| {
            try encodeHeader(allocator, &output, header.name, header.value);
        }
        return output.toOwnedSlice(allocator);
    }
};

fn encodeHeader(allocator: std.mem.Allocator, out: *std.ArrayList(u8), name: []const u8, value: []const u8) EncoderError!void {
    if (h2_static.staticIndex(name, value)) |idx| {
        // Indexed Header Field — 7-bit prefix, high bit set.
        try encodeInteger(allocator, out, idx, 7, 0x80);
        return;
    }
    // Literal Header Field without Indexing — 4-bit name-index prefix.
    if (h2_static.staticNameIndex(name)) |ni| {
        try encodeInteger(allocator, out, ni, 4, 0x00);
    } else {
        try encodeInteger(allocator, out, 0, 4, 0x00);
        try encodeString(allocator, out, name);
    }
    try encodeString(allocator, out, value);
}

// RFC 7541 §5.1 prefix-integer encode. `flags` holds the representation's
// high bits OR'd into the prefix byte.
fn encodeInteger(allocator: std.mem.Allocator, out: *std.ArrayList(u8), value: usize, comptime prefix_bits: u4, flags: u8) EncoderError!void {
    const max_prefix: usize = (@as(usize, 1) << prefix_bits) - 1;
    if (value < max_prefix) {
        try out.append(allocator, flags | @as(u8, @intCast(value)));
        return;
    }
    try out.append(allocator, flags | @as(u8, @intCast(max_prefix)));
    var v = value - max_prefix;
    while (v >= 128) {
        try out.append(allocator, @as(u8, @intCast((v & 0x7F) | 0x80)));
        v >>= 7;
    }
    try out.append(allocator, @as(u8, @intCast(v)));
}

// RFC 7541 §5.2 string literal: H-bit + integer length (7-bit prefix) +
// octets. Huffman-encodes when that is strictly shorter.
fn encodeString(allocator: std.mem.Allocator, out: *std.ArrayList(u8), s: []const u8) EncoderError!void {
    const hlen = huffman.encodedLen(s);
    if (hlen < s.len) {
        try encodeInteger(allocator, out, hlen, 7, 0x80);
        const enc = try huffman.encode(allocator, s);
        defer allocator.free(enc);
        try out.appendSlice(allocator, enc);
    } else {
        try encodeInteger(allocator, out, s.len, 7, 0x00);
        try out.appendSlice(allocator, s);
    }
}

const h2 = @import("h2.zig");

test "encoder/decoder round-trip incl. long values and Huffman" {
    const a = std.testing.allocator;
    const headers = [_]Header{
        .{ .name = ":status", .value = "200" }, // full static index
        .{ .name = "content-type", .value = "text/html; charset=utf-8" }, // static name, literal value
        .{ .name = "location", .value = "https://example.com/" ++ "a" ** 300 }, // value >> 128 bytes
        .{ .name = "x-custom-header", .value = "some-value-123" }, // literal name + value
        .{ .name = "set-cookie", .value = "sid=" ++ "b" ** 200 ++ "; Path=/; HttpOnly" },
    };
    const wire = try Encoder.encode(&headers, a);
    defer a.free(wire);

    var dec = h2.Decoder.init(a);
    defer dec.deinit();
    var out: std.ArrayList(h2.Header) = .empty;
    defer out.deinit(a);
    try dec.decode(wire, &out);

    try std.testing.expectEqual(headers.len, out.items.len);
    for (headers, out.items) |expected, got| {
        try std.testing.expectEqualStrings(expected.name, got.name);
        try std.testing.expectEqualStrings(expected.value, got.value);
    }
}
