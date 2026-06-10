// HPACK Huffman coding (RFC 7541 Appendix B).
//
// v1.10: real HTTP/2 clients (browsers, curl, python-h2) Huffman-encode
// header strings by default. Earlier releases shipped an HPACK decoder
// that ignored the Huffman bit entirely, so every realistic HTTP/2
// request decoded to garbage. This module implements the canonical
// static Huffman table for both directions.
//
// The table below is generated verbatim from the authoritative
// `hpack.huffman_constants` (RFC 7541 Table). Index == symbol value;
// index 256 is the EOS marker (never emitted, only used as padding).

const std = @import("std");

pub const HuffmanError = error{
    /// An EOS symbol appeared inside the encoded data (must only be padding).
    InvalidEos,
    /// Padding longer than 7 bits, or a code longer than the table allows.
    InvalidPadding,
    /// Trailing padding bits were not all-ones (EOS prefix).
    InvalidPrefix,
    OutOfMemory,
};

const Code = struct { code: u32, nbits: u5 };

pub const CODES = [257]Code{
    .{ .code = 0x1ff8, .nbits = 13 },
    .{ .code = 0x7fffd8, .nbits = 23 },
    .{ .code = 0xfffffe2, .nbits = 28 },
    .{ .code = 0xfffffe3, .nbits = 28 },
    .{ .code = 0xfffffe4, .nbits = 28 },
    .{ .code = 0xfffffe5, .nbits = 28 },
    .{ .code = 0xfffffe6, .nbits = 28 },
    .{ .code = 0xfffffe7, .nbits = 28 },
    .{ .code = 0xfffffe8, .nbits = 28 },
    .{ .code = 0xffffea, .nbits = 24 },
    .{ .code = 0x3ffffffc, .nbits = 30 },
    .{ .code = 0xfffffe9, .nbits = 28 },
    .{ .code = 0xfffffea, .nbits = 28 },
    .{ .code = 0x3ffffffd, .nbits = 30 },
    .{ .code = 0xfffffeb, .nbits = 28 },
    .{ .code = 0xfffffec, .nbits = 28 },
    .{ .code = 0xfffffed, .nbits = 28 },
    .{ .code = 0xfffffee, .nbits = 28 },
    .{ .code = 0xfffffef, .nbits = 28 },
    .{ .code = 0xffffff0, .nbits = 28 },
    .{ .code = 0xffffff1, .nbits = 28 },
    .{ .code = 0xffffff2, .nbits = 28 },
    .{ .code = 0x3ffffffe, .nbits = 30 },
    .{ .code = 0xffffff3, .nbits = 28 },
    .{ .code = 0xffffff4, .nbits = 28 },
    .{ .code = 0xffffff5, .nbits = 28 },
    .{ .code = 0xffffff6, .nbits = 28 },
    .{ .code = 0xffffff7, .nbits = 28 },
    .{ .code = 0xffffff8, .nbits = 28 },
    .{ .code = 0xffffff9, .nbits = 28 },
    .{ .code = 0xffffffa, .nbits = 28 },
    .{ .code = 0xffffffb, .nbits = 28 },
    .{ .code = 0x14, .nbits = 6 },
    .{ .code = 0x3f8, .nbits = 10 },
    .{ .code = 0x3f9, .nbits = 10 },
    .{ .code = 0xffa, .nbits = 12 },
    .{ .code = 0x1ff9, .nbits = 13 },
    .{ .code = 0x15, .nbits = 6 },
    .{ .code = 0xf8, .nbits = 8 },
    .{ .code = 0x7fa, .nbits = 11 },
    .{ .code = 0x3fa, .nbits = 10 },
    .{ .code = 0x3fb, .nbits = 10 },
    .{ .code = 0xf9, .nbits = 8 },
    .{ .code = 0x7fb, .nbits = 11 },
    .{ .code = 0xfa, .nbits = 8 },
    .{ .code = 0x16, .nbits = 6 },
    .{ .code = 0x17, .nbits = 6 },
    .{ .code = 0x18, .nbits = 6 },
    .{ .code = 0x0, .nbits = 5 },
    .{ .code = 0x1, .nbits = 5 },
    .{ .code = 0x2, .nbits = 5 },
    .{ .code = 0x19, .nbits = 6 },
    .{ .code = 0x1a, .nbits = 6 },
    .{ .code = 0x1b, .nbits = 6 },
    .{ .code = 0x1c, .nbits = 6 },
    .{ .code = 0x1d, .nbits = 6 },
    .{ .code = 0x1e, .nbits = 6 },
    .{ .code = 0x1f, .nbits = 6 },
    .{ .code = 0x5c, .nbits = 7 },
    .{ .code = 0xfb, .nbits = 8 },
    .{ .code = 0x7ffc, .nbits = 15 },
    .{ .code = 0x20, .nbits = 6 },
    .{ .code = 0xffb, .nbits = 12 },
    .{ .code = 0x3fc, .nbits = 10 },
    .{ .code = 0x1ffa, .nbits = 13 },
    .{ .code = 0x21, .nbits = 6 },
    .{ .code = 0x5d, .nbits = 7 },
    .{ .code = 0x5e, .nbits = 7 },
    .{ .code = 0x5f, .nbits = 7 },
    .{ .code = 0x60, .nbits = 7 },
    .{ .code = 0x61, .nbits = 7 },
    .{ .code = 0x62, .nbits = 7 },
    .{ .code = 0x63, .nbits = 7 },
    .{ .code = 0x64, .nbits = 7 },
    .{ .code = 0x65, .nbits = 7 },
    .{ .code = 0x66, .nbits = 7 },
    .{ .code = 0x67, .nbits = 7 },
    .{ .code = 0x68, .nbits = 7 },
    .{ .code = 0x69, .nbits = 7 },
    .{ .code = 0x6a, .nbits = 7 },
    .{ .code = 0x6b, .nbits = 7 },
    .{ .code = 0x6c, .nbits = 7 },
    .{ .code = 0x6d, .nbits = 7 },
    .{ .code = 0x6e, .nbits = 7 },
    .{ .code = 0x6f, .nbits = 7 },
    .{ .code = 0x70, .nbits = 7 },
    .{ .code = 0x71, .nbits = 7 },
    .{ .code = 0x72, .nbits = 7 },
    .{ .code = 0xfc, .nbits = 8 },
    .{ .code = 0x73, .nbits = 7 },
    .{ .code = 0xfd, .nbits = 8 },
    .{ .code = 0x1ffb, .nbits = 13 },
    .{ .code = 0x7fff0, .nbits = 19 },
    .{ .code = 0x1ffc, .nbits = 13 },
    .{ .code = 0x3ffc, .nbits = 14 },
    .{ .code = 0x22, .nbits = 6 },
    .{ .code = 0x7ffd, .nbits = 15 },
    .{ .code = 0x3, .nbits = 5 },
    .{ .code = 0x23, .nbits = 6 },
    .{ .code = 0x4, .nbits = 5 },
    .{ .code = 0x24, .nbits = 6 },
    .{ .code = 0x5, .nbits = 5 },
    .{ .code = 0x25, .nbits = 6 },
    .{ .code = 0x26, .nbits = 6 },
    .{ .code = 0x27, .nbits = 6 },
    .{ .code = 0x6, .nbits = 5 },
    .{ .code = 0x74, .nbits = 7 },
    .{ .code = 0x75, .nbits = 7 },
    .{ .code = 0x28, .nbits = 6 },
    .{ .code = 0x29, .nbits = 6 },
    .{ .code = 0x2a, .nbits = 6 },
    .{ .code = 0x7, .nbits = 5 },
    .{ .code = 0x2b, .nbits = 6 },
    .{ .code = 0x76, .nbits = 7 },
    .{ .code = 0x2c, .nbits = 6 },
    .{ .code = 0x8, .nbits = 5 },
    .{ .code = 0x9, .nbits = 5 },
    .{ .code = 0x2d, .nbits = 6 },
    .{ .code = 0x77, .nbits = 7 },
    .{ .code = 0x78, .nbits = 7 },
    .{ .code = 0x79, .nbits = 7 },
    .{ .code = 0x7a, .nbits = 7 },
    .{ .code = 0x7b, .nbits = 7 },
    .{ .code = 0x7ffe, .nbits = 15 },
    .{ .code = 0x7fc, .nbits = 11 },
    .{ .code = 0x3ffd, .nbits = 14 },
    .{ .code = 0x1ffd, .nbits = 13 },
    .{ .code = 0xffffffc, .nbits = 28 },
    .{ .code = 0xfffe6, .nbits = 20 },
    .{ .code = 0x3fffd2, .nbits = 22 },
    .{ .code = 0xfffe7, .nbits = 20 },
    .{ .code = 0xfffe8, .nbits = 20 },
    .{ .code = 0x3fffd3, .nbits = 22 },
    .{ .code = 0x3fffd4, .nbits = 22 },
    .{ .code = 0x3fffd5, .nbits = 22 },
    .{ .code = 0x7fffd9, .nbits = 23 },
    .{ .code = 0x3fffd6, .nbits = 22 },
    .{ .code = 0x7fffda, .nbits = 23 },
    .{ .code = 0x7fffdb, .nbits = 23 },
    .{ .code = 0x7fffdc, .nbits = 23 },
    .{ .code = 0x7fffdd, .nbits = 23 },
    .{ .code = 0x7fffde, .nbits = 23 },
    .{ .code = 0xffffeb, .nbits = 24 },
    .{ .code = 0x7fffdf, .nbits = 23 },
    .{ .code = 0xffffec, .nbits = 24 },
    .{ .code = 0xffffed, .nbits = 24 },
    .{ .code = 0x3fffd7, .nbits = 22 },
    .{ .code = 0x7fffe0, .nbits = 23 },
    .{ .code = 0xffffee, .nbits = 24 },
    .{ .code = 0x7fffe1, .nbits = 23 },
    .{ .code = 0x7fffe2, .nbits = 23 },
    .{ .code = 0x7fffe3, .nbits = 23 },
    .{ .code = 0x7fffe4, .nbits = 23 },
    .{ .code = 0x1fffdc, .nbits = 21 },
    .{ .code = 0x3fffd8, .nbits = 22 },
    .{ .code = 0x7fffe5, .nbits = 23 },
    .{ .code = 0x3fffd9, .nbits = 22 },
    .{ .code = 0x7fffe6, .nbits = 23 },
    .{ .code = 0x7fffe7, .nbits = 23 },
    .{ .code = 0xffffef, .nbits = 24 },
    .{ .code = 0x3fffda, .nbits = 22 },
    .{ .code = 0x1fffdd, .nbits = 21 },
    .{ .code = 0xfffe9, .nbits = 20 },
    .{ .code = 0x3fffdb, .nbits = 22 },
    .{ .code = 0x3fffdc, .nbits = 22 },
    .{ .code = 0x7fffe8, .nbits = 23 },
    .{ .code = 0x7fffe9, .nbits = 23 },
    .{ .code = 0x1fffde, .nbits = 21 },
    .{ .code = 0x7fffea, .nbits = 23 },
    .{ .code = 0x3fffdd, .nbits = 22 },
    .{ .code = 0x3fffde, .nbits = 22 },
    .{ .code = 0xfffff0, .nbits = 24 },
    .{ .code = 0x1fffdf, .nbits = 21 },
    .{ .code = 0x3fffdf, .nbits = 22 },
    .{ .code = 0x7fffeb, .nbits = 23 },
    .{ .code = 0x7fffec, .nbits = 23 },
    .{ .code = 0x1fffe0, .nbits = 21 },
    .{ .code = 0x1fffe1, .nbits = 21 },
    .{ .code = 0x3fffe0, .nbits = 22 },
    .{ .code = 0x1fffe2, .nbits = 21 },
    .{ .code = 0x7fffed, .nbits = 23 },
    .{ .code = 0x3fffe1, .nbits = 22 },
    .{ .code = 0x7fffee, .nbits = 23 },
    .{ .code = 0x7fffef, .nbits = 23 },
    .{ .code = 0xfffea, .nbits = 20 },
    .{ .code = 0x3fffe2, .nbits = 22 },
    .{ .code = 0x3fffe3, .nbits = 22 },
    .{ .code = 0x3fffe4, .nbits = 22 },
    .{ .code = 0x7ffff0, .nbits = 23 },
    .{ .code = 0x3fffe5, .nbits = 22 },
    .{ .code = 0x3fffe6, .nbits = 22 },
    .{ .code = 0x7ffff1, .nbits = 23 },
    .{ .code = 0x3ffffe0, .nbits = 26 },
    .{ .code = 0x3ffffe1, .nbits = 26 },
    .{ .code = 0xfffeb, .nbits = 20 },
    .{ .code = 0x7fff1, .nbits = 19 },
    .{ .code = 0x3fffe7, .nbits = 22 },
    .{ .code = 0x7ffff2, .nbits = 23 },
    .{ .code = 0x3fffe8, .nbits = 22 },
    .{ .code = 0x1ffffec, .nbits = 25 },
    .{ .code = 0x3ffffe2, .nbits = 26 },
    .{ .code = 0x3ffffe3, .nbits = 26 },
    .{ .code = 0x3ffffe4, .nbits = 26 },
    .{ .code = 0x7ffffde, .nbits = 27 },
    .{ .code = 0x7ffffdf, .nbits = 27 },
    .{ .code = 0x3ffffe5, .nbits = 26 },
    .{ .code = 0xfffff1, .nbits = 24 },
    .{ .code = 0x1ffffed, .nbits = 25 },
    .{ .code = 0x7fff2, .nbits = 19 },
    .{ .code = 0x1fffe3, .nbits = 21 },
    .{ .code = 0x3ffffe6, .nbits = 26 },
    .{ .code = 0x7ffffe0, .nbits = 27 },
    .{ .code = 0x7ffffe1, .nbits = 27 },
    .{ .code = 0x3ffffe7, .nbits = 26 },
    .{ .code = 0x7ffffe2, .nbits = 27 },
    .{ .code = 0xfffff2, .nbits = 24 },
    .{ .code = 0x1fffe4, .nbits = 21 },
    .{ .code = 0x1fffe5, .nbits = 21 },
    .{ .code = 0x3ffffe8, .nbits = 26 },
    .{ .code = 0x3ffffe9, .nbits = 26 },
    .{ .code = 0xffffffd, .nbits = 28 },
    .{ .code = 0x7ffffe3, .nbits = 27 },
    .{ .code = 0x7ffffe4, .nbits = 27 },
    .{ .code = 0x7ffffe5, .nbits = 27 },
    .{ .code = 0xfffec, .nbits = 20 },
    .{ .code = 0xfffff3, .nbits = 24 },
    .{ .code = 0xfffed, .nbits = 20 },
    .{ .code = 0x1fffe6, .nbits = 21 },
    .{ .code = 0x3fffe9, .nbits = 22 },
    .{ .code = 0x1fffe7, .nbits = 21 },
    .{ .code = 0x1fffe8, .nbits = 21 },
    .{ .code = 0x7ffff3, .nbits = 23 },
    .{ .code = 0x3fffea, .nbits = 22 },
    .{ .code = 0x3fffeb, .nbits = 22 },
    .{ .code = 0x1ffffee, .nbits = 25 },
    .{ .code = 0x1ffffef, .nbits = 25 },
    .{ .code = 0xfffff4, .nbits = 24 },
    .{ .code = 0xfffff5, .nbits = 24 },
    .{ .code = 0x3ffffea, .nbits = 26 },
    .{ .code = 0x7ffff4, .nbits = 23 },
    .{ .code = 0x3ffffeb, .nbits = 26 },
    .{ .code = 0x7ffffe6, .nbits = 27 },
    .{ .code = 0x3ffffec, .nbits = 26 },
    .{ .code = 0x3ffffed, .nbits = 26 },
    .{ .code = 0x7ffffe7, .nbits = 27 },
    .{ .code = 0x7ffffe8, .nbits = 27 },
    .{ .code = 0x7ffffe9, .nbits = 27 },
    .{ .code = 0x7ffffea, .nbits = 27 },
    .{ .code = 0x7ffffeb, .nbits = 27 },
    .{ .code = 0xffffffe, .nbits = 28 },
    .{ .code = 0x7ffffec, .nbits = 27 },
    .{ .code = 0x7ffffed, .nbits = 27 },
    .{ .code = 0x7ffffee, .nbits = 27 },
    .{ .code = 0x7ffffef, .nbits = 27 },
    .{ .code = 0x7fffff0, .nbits = 27 },
    .{ .code = 0x3ffffee, .nbits = 26 },
    .{ .code = 0x3fffffff, .nbits = 30 }, // 256: EOS
};

const SymEntry = struct { nbits: u5, code: u32, sym: u16 };

// Symbols sorted by (nbits, code) so the decoder can scan only the bucket
// for the current bit-length. Built at comptime — zero runtime cost.
const SORTED: [257]SymEntry = blk: {
    @setEvalBranchQuota(200000);
    var arr: [257]SymEntry = undefined;
    for (CODES, 0..) |c, s| arr[s] = .{ .nbits = c.nbits, .code = c.code, .sym = @intCast(s) };
    // insertion sort (comptime, tiny N)
    var i: usize = 1;
    while (i < 257) : (i += 1) {
        var j: usize = i;
        while (j > 0 and (arr[j].nbits < arr[j - 1].nbits or
            (arr[j].nbits == arr[j - 1].nbits and arr[j].code < arr[j - 1].code))) : (j -= 1)
        {
            const t = arr[j];
            arr[j] = arr[j - 1];
            arr[j - 1] = t;
        }
    }
    break :blk arr;
};

// LEN_OFF[L] = index of the first SORTED entry whose nbits >= L. The bucket
// for codes of exactly length L is SORTED[LEN_OFF[L]..LEN_OFF[L+1]].
const LEN_OFF: [32]u16 = blk: {
    var off: [32]u16 = .{0} ** 32;
    var l: usize = 0;
    var idx: usize = 0;
    while (l <= 31) : (l += 1) {
        while (idx < 257 and SORTED[idx].nbits < l) : (idx += 1) {}
        off[l] = @intCast(idx);
    }
    break :blk off;
};

fn matchAtLen(len: u5, code: u32) ?u16 {
    if (len == 0 or len > 30) return null;
    const lo = LEN_OFF[len];
    const hi = LEN_OFF[len + 1];
    var k: usize = lo;
    while (k < hi) : (k += 1) {
        if (SORTED[k].code == code) return SORTED[k].sym;
    }
    return null;
}

/// Decode an HPACK Huffman-coded byte string. Returns an owned slice the
/// caller must free with `allocator`.
pub fn decode(allocator: std.mem.Allocator, input: []const u8) HuffmanError![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);

    var acc: u32 = 0;
    var cur: u5 = 0;
    for (input) |byte| {
        var k: u4 = 0;
        while (k < 8) : (k += 1) {
            const bit: u1 = @truncate(byte >> @intCast(7 - k));
            acc = (acc << 1) | bit;
            // A code can be at most 30 bits; exceeding it without a match is
            // a malformed stream (or a forbidden EOS-prefixed run).
            if (cur == 30) return error.InvalidPadding;
            cur += 1;
            if (matchAtLen(cur, acc)) |sym| {
                if (sym == 256) return error.InvalidEos;
                try out.append(allocator, @intCast(sym));
                acc = 0;
                cur = 0;
            }
        }
    }
    // RFC 7541 §5.2: any leftover (< 8) bits must be the most-significant
    // bits of the EOS code, i.e. all ones. A run of >= 8 padding bits, or
    // padding that isn't all-ones, is a decode error.
    if (cur >= 8) return error.InvalidPadding;
    if (cur > 0) {
        const mask: u32 = (@as(u32, 1) << cur) - 1;
        if (acc != mask) return error.InvalidPrefix;
    }
    return out.toOwnedSlice(allocator);
}

/// Huffman-encode `input`. Returns an owned slice. Used by the encoder when
/// the compressed form is shorter, and by the test suite for round-trips.
pub fn encode(allocator: std.mem.Allocator, input: []const u8) error{OutOfMemory}![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);

    var acc: u64 = 0;
    var nbits: u7 = 0;
    for (input) |b| {
        const c = CODES[b];
        acc = (acc << c.nbits) | c.code;
        nbits += c.nbits;
        while (nbits >= 8) {
            nbits -= 8;
            try out.append(allocator, @truncate(acc >> @intCast(nbits)));
        }
    }
    if (nbits > 0) {
        const pad: u7 = 8 - nbits;
        acc = (acc << @intCast(pad)) | ((@as(u64, 1) << @intCast(pad)) - 1);
        try out.append(allocator, @truncate(acc));
    }
    return out.toOwnedSlice(allocator);
}

/// Number of bytes `encode(input)` would produce, without allocating. Lets
/// the encoder choose the shorter of literal vs Huffman per RFC 7541 §5.2.
pub fn encodedLen(input: []const u8) usize {
    var bits: usize = 0;
    for (input) |b| bits += CODES[b].nbits;
    return (bits + 7) / 8;
}

test "huffman is a valid prefix code" {
    // No code may be a prefix of another. Check pairwise via left-aligned
    // comparison of the shorter against the longer.
    for (CODES, 0..) |a, ai| {
        for (CODES, 0..) |b, bi| {
            if (ai == bi) continue;
            if (a.nbits > b.nbits) continue;
            const shift: u5 = b.nbits - a.nbits;
            if ((b.code >> shift) == a.code) {
                std.debug.print("prefix clash: {d} is prefix of {d}\n", .{ ai, bi });
                return error.PrefixClash;
            }
        }
    }
}

test "huffman round-trips every byte value" {
    const a = std.testing.allocator;
    var buf: [256]u8 = undefined;
    for (0..256) |i| buf[i] = @intCast(i);
    const enc = try encode(a, &buf);
    defer a.free(enc);
    const dec = try decode(a, enc);
    defer a.free(dec);
    try std.testing.expectEqualSlices(u8, &buf, dec);
}

test "huffman RFC 7541 C.4 vectors" {
    const a = std.testing.allocator;
    const cases = [_]struct { plain: []const u8, wire: []const u8 }{
        .{ .plain = "www.example.com", .wire = &.{ 0xf1, 0xe3, 0xc2, 0xe5, 0xf2, 0x3a, 0x6b, 0xa0, 0xab, 0x90, 0xf4, 0xff } },
        .{ .plain = "no-cache", .wire = &.{ 0xa8, 0xeb, 0x10, 0x64, 0x9c, 0xbf } },
        .{ .plain = "custom-key", .wire = &.{ 0x25, 0xa8, 0x49, 0xe9, 0x5b, 0xa9, 0x7d, 0x7f } },
        .{ .plain = "custom-value", .wire = &.{ 0x25, 0xa8, 0x49, 0xe9, 0x5b, 0xb8, 0xe8, 0xb4, 0xbf } },
    };
    for (cases) |c| {
        const enc = try encode(a, c.plain);
        defer a.free(enc);
        try std.testing.expectEqualSlices(u8, c.wire, enc);
        const dec = try decode(a, c.wire);
        defer a.free(dec);
        try std.testing.expectEqualSlices(u8, c.plain, dec);
    }
}

test "huffman rejects embedded EOS" {
    const a = std.testing.allocator;
    // 30 one-bits = full EOS code, then padding → must be rejected.
    const bad = [_]u8{ 0xff, 0xff, 0xff, 0xff };
    try std.testing.expectError(error.InvalidEos, decode(a, &bad));
}
