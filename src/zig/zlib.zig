// Lazy-loaded zlib for v1.4 request decompression + response
// compression. Same dlopen pattern as `tls.zig`: plain-HTTP /
// no-compression deployments never load libz, so the wheel doesn't
// vendor it and the process doesn't pay the ~80 KiB lib mapping.
//
// Only `inflate*` / `deflate*` symbols we actually use are resolved
// up-front once the library loads. Subsequent calls go through the
// function-pointer table — one extra cache miss vs a linked path,
// negligible.

const std = @import("std");
const builtin = @import("builtin");

const dl = @cImport({
    @cInclude("dlfcn.h");
});

/// Opaque z_stream — we only ever pass pointers, never look inside.
pub const ZStream = extern struct {
    next_in: ?[*]const u8,
    avail_in: c_uint,
    total_in: c_ulong,
    next_out: ?[*]u8,
    avail_out: c_uint,
    total_out: c_ulong,
    msg: ?[*:0]const u8,
    state: ?*anyopaque,
    zalloc: ?*anyopaque,
    zfree: ?*anyopaque,
    opaque_field: ?*anyopaque,
    data_type: c_int,
    adler: c_ulong,
    reserved: c_ulong,
};

// zlib return codes (stable ABI).
pub const Z_OK: c_int = 0;
pub const Z_STREAM_END: c_int = 1;
pub const Z_NEED_DICT: c_int = 2;
pub const Z_BUF_ERROR: c_int = -5;
pub const Z_NO_FLUSH: c_int = 0;
pub const Z_FINISH: c_int = 4;
pub const Z_SYNC_FLUSH: c_int = 2;
pub const Z_DEFLATED: c_int = 8;
pub const Z_DEFAULT_STRATEGY: c_int = 0;
pub const Z_DEFAULT_COMPRESSION: c_int = -1;

const Funcs = struct {
    inflateInit2_: *const fn (*ZStream, c_int, [*c]const u8, c_int) callconv(.c) c_int,
    inflate: *const fn (*ZStream, c_int) callconv(.c) c_int,
    inflateEnd: *const fn (*ZStream) callconv(.c) c_int,
    deflateInit2_: *const fn (*ZStream, c_int, c_int, c_int, c_int, c_int, [*c]const u8, c_int) callconv(.c) c_int,
    deflate: *const fn (*ZStream, c_int) callconv(.c) c_int,
    deflateEnd: *const fn (*ZStream) callconv(.c) c_int,
    zlibVersion: *const fn () callconv(.c) [*:0]const u8,
};

var funcs: ?Funcs = null;
var libz_handle: ?*anyopaque = null;

const SONAMES = [_][:0]const u8{
    "libz.so.1",
    "libz.so",
};

fn loadFuncs() bool {
    if (funcs != null) return true;
    for (SONAMES) |name| {
        const h = dl.dlopen(name.ptr, dl.RTLD_NOW | dl.RTLD_GLOBAL);
        if (h != null) {
            libz_handle = h;
            break;
        }
    }
    if (libz_handle == null) return false;

    var f: Funcs = undefined;
    inline for (@typeInfo(Funcs).@"struct".fields) |field| {
        const sym = dl.dlsym(libz_handle, field.name.ptr);
        if (sym == null) {
            _ = dl.dlclose(libz_handle);
            libz_handle = null;
            return false;
        }
        @field(f, field.name) = @ptrCast(@alignCast(sym));
    }
    funcs = f;
    return true;
}

pub fn isAvailable() bool {
    return loadFuncs();
}

/// Best-effort one-shot gzip decompression. Returns the decompressed
/// bytes (caller-owned). Caller's `dst_cap` upper-bounds the output —
/// over-cap returns null (defends against zip-bombs). Used by the
/// request-body path to decode `Content-Encoding: gzip` payloads.
/// Window bits 31 = gzip (raw deflate is 15, zlib is 15 too, gzip
/// adds 16 to the wbits).
pub fn gunzip(src: []const u8, allocator: std.mem.Allocator, dst_cap: usize) ?[]u8 {
    if (!loadFuncs()) return null;
    const f = funcs.?;
    var stream: ZStream = std.mem.zeroes(ZStream);
    if (f.inflateInit2_(&stream, 15 + 16, f.zlibVersion(), @sizeOf(ZStream)) != Z_OK) return null;
    defer _ = f.inflateEnd(&stream);

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(allocator);
    out.ensureTotalCapacity(allocator, @min(dst_cap, src.len * 4)) catch return null;

    stream.next_in = src.ptr;
    stream.avail_in = @intCast(src.len);
    var chunk: [16 * 1024]u8 = undefined;
    while (true) {
        stream.next_out = &chunk;
        stream.avail_out = chunk.len;
        const rc = f.inflate(&stream, Z_NO_FLUSH);
        const produced = chunk.len - stream.avail_out;
        if (produced > 0) {
            if (out.items.len + produced > dst_cap) return null;
            out.appendSlice(allocator, chunk[0..produced]) catch return null;
        }
        if (rc == Z_STREAM_END) break;
        if (rc != Z_OK) return null;
        if (stream.avail_in == 0 and stream.avail_out == chunk.len) break;
    }
    return out.toOwnedSlice(allocator) catch null;
}

/// Streaming gzip-encode `src` → caller-owned bytes. Used by the
/// response path when `Accept-Encoding: gzip` was negotiated.
/// `level` is `Z_DEFAULT_COMPRESSION` (= 6) by default; valid range
/// 0..9. Higher = more CPU + smaller output.
pub fn gzipEncode(src: []const u8, allocator: std.mem.Allocator, level: c_int) ?[]u8 {
    if (!loadFuncs()) return null;
    const f = funcs.?;
    var stream: ZStream = std.mem.zeroes(ZStream);
    if (f.deflateInit2_(
        &stream,
        level,
        Z_DEFLATED,
        15 + 16, // gzip wrapper
        8, // memLevel
        Z_DEFAULT_STRATEGY,
        f.zlibVersion(),
        @sizeOf(ZStream),
    ) != Z_OK) return null;
    defer _ = f.deflateEnd(&stream);

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(allocator);
    out.ensureTotalCapacity(allocator, src.len / 2) catch return null;

    stream.next_in = src.ptr;
    stream.avail_in = @intCast(src.len);
    var chunk: [16 * 1024]u8 = undefined;
    while (true) {
        stream.next_out = &chunk;
        stream.avail_out = chunk.len;
        const rc = f.deflate(&stream, Z_FINISH);
        const produced = chunk.len - stream.avail_out;
        if (produced > 0) {
            out.appendSlice(allocator, chunk[0..produced]) catch return null;
        }
        if (rc == Z_STREAM_END) break;
        if (rc != Z_OK) return null;
    }
    return out.toOwnedSlice(allocator) catch null;
}
