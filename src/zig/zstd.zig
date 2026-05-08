// Lazy-loaded libzstd for v1.4 response compression. Same dlopen
// pattern as `zlib.zig`. Plain-HTTP / non-zstd deployments never load
// libzstd, so the wheel doesn't vendor it and the process doesn't pay
// the lib mapping.

const std = @import("std");

const dl = @cImport({
    @cInclude("dlfcn.h");
});

// zstd public ABI: stable across 1.x. v1.6 adds the streaming surface
// (`ZSTD_createCCtx` + `ZSTD_compressStream2` + `ZSTD_freeCCtx`) so
// the dispatcher can carry a CCtx across `_send` calls.
const Funcs = struct {
    ZSTD_compressBound: *const fn (usize) callconv(.c) usize,
    ZSTD_compress: *const fn ([*]u8, usize, [*]const u8, usize, c_int) callconv(.c) usize,
    ZSTD_isError: *const fn (usize) callconv(.c) c_uint,
    ZSTD_getFrameContentSize: *const fn ([*]const u8, usize) callconv(.c) c_ulonglong,
    ZSTD_decompress: *const fn ([*]u8, usize, [*]const u8, usize) callconv(.c) usize,
    ZSTD_createCCtx: *const fn () callconv(.c) ?*anyopaque,
    ZSTD_freeCCtx: *const fn (?*anyopaque) callconv(.c) usize,
    ZSTD_CCtx_setParameter: *const fn (?*anyopaque, c_int, c_int) callconv(.c) usize,
    ZSTD_compressStream2: *const fn (?*anyopaque, *ZstdOutBuffer, *ZstdInBuffer, c_int) callconv(.c) usize,
};

pub const ZstdInBuffer = extern struct {
    src: [*]const u8,
    size: usize,
    pos: usize,
};
pub const ZstdOutBuffer = extern struct {
    dst: [*]u8,
    size: usize,
    pos: usize,
};

// ZSTD_EndDirective. v1.6 streaming uses `flush` per intermediate
// chunk + `end` on the final.
pub const ZSTD_e_continue: c_int = 0;
pub const ZSTD_e_flush: c_int = 1;
pub const ZSTD_e_end: c_int = 2;
// ZSTD_cParameter
pub const ZSTD_c_compressionLevel: c_int = 100;

var funcs: ?Funcs = null;
var lib_handle: ?*anyopaque = null;

const SONAMES = [_][:0]const u8{
    "libzstd.so.1",
    "libzstd.so",
};

pub const DEFAULT_LEVEL: c_int = 3; // zstd's "fast" sweet spot for HTTP

// `ZSTD_getFrameContentSize` sentinel values.
const ZSTD_CONTENTSIZE_UNKNOWN: c_ulonglong = 0xFFFF_FFFF_FFFF_FFFE;
const ZSTD_CONTENTSIZE_ERROR: c_ulonglong = 0xFFFF_FFFF_FFFF_FFFF;

fn loadFuncs() bool {
    if (funcs != null) return true;
    for (SONAMES) |name| {
        const h = dl.dlopen(name.ptr, dl.RTLD_NOW | dl.RTLD_GLOBAL);
        if (h != null) {
            lib_handle = h;
            break;
        }
    }
    if (lib_handle == null) return false;
    var f: Funcs = undefined;
    inline for (@typeInfo(Funcs).@"struct".fields) |field| {
        const sym = dl.dlsym(lib_handle, field.name.ptr);
        if (sym == null) {
            _ = dl.dlclose(lib_handle);
            lib_handle = null;
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

/// One-shot zstd compress. Returns caller-owned bytes or null on libzstd
/// miss / encoder error.
pub fn zstdEncode(src: []const u8, allocator: std.mem.Allocator, level: c_int) ?[]u8 {
    if (!loadFuncs()) return null;
    const f = funcs.?;
    const lvl: c_int = if (level == 0) DEFAULT_LEVEL else level;
    const max_out = f.ZSTD_compressBound(src.len);
    const buf = allocator.alloc(u8, max_out) catch return null;
    const written = f.ZSTD_compress(buf.ptr, max_out, src.ptr, src.len, lvl);
    if (f.ZSTD_isError(written) != 0) {
        allocator.free(buf);
        return null;
    }
    if (written == max_out) return buf;
    return allocator.realloc(buf, written) catch buf[0..written];
}

/// One-shot zstd decompress with `max_size` cap (zip-bomb defense). Frame
/// content size is queried first; missing or > cap returns null without
/// allocating output.
pub fn zstdDecode(src: []const u8, allocator: std.mem.Allocator, max_size: usize) ?[]u8 {
    if (!loadFuncs()) return null;
    const f = funcs.?;
    const declared = f.ZSTD_getFrameContentSize(src.ptr, src.len);
    if (declared == ZSTD_CONTENTSIZE_ERROR) return null;
    // When the encoder didn't record content size, fall back to the cap.
    const out_cap: usize = if (declared == ZSTD_CONTENTSIZE_UNKNOWN)
        max_size
    else if (declared > max_size)
        return null
    else
        @intCast(declared);
    if (out_cap == 0) return allocator.alloc(u8, 0) catch null;
    const buf = allocator.alloc(u8, out_cap) catch return null;
    const written = f.ZSTD_decompress(buf.ptr, out_cap, src.ptr, src.len);
    if (f.ZSTD_isError(written) != 0) {
        allocator.free(buf);
        return null;
    }
    if (written == out_cap) return buf;
    return allocator.realloc(buf, written) catch buf[0..written];
}

/// Create a streaming zstd compression context. Returns the libzstd
/// `ZSTD_CCtx*` as an opaque handle, or null on libzstd miss.
pub fn streamCreate(level: c_int) ?*anyopaque {
    if (!loadFuncs()) return null;
    const f = funcs.?;
    const cctx = f.ZSTD_createCCtx() orelse return null;
    const lvl: c_int = if (level == 0) DEFAULT_LEVEL else level;
    _ = f.ZSTD_CCtx_setParameter(cctx, ZSTD_c_compressionLevel, lvl);
    return cctx;
}

/// Feed `chunk` into the encoder, drain produced output, return
/// caller-owned bytes. `finish=true` on the last call closes the
/// frame (writes the zstd trailer). Returns null on encode error.
pub fn streamCompress(
    state: *anyopaque,
    chunk: []const u8,
    allocator: std.mem.Allocator,
    finish: bool,
) ?[]u8 {
    const f = funcs.?;
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(allocator);
    out.ensureTotalCapacity(allocator, chunk.len + 64) catch return null;

    var in_buf: ZstdInBuffer = .{ .src = if (chunk.len > 0) chunk.ptr else @ptrFromInt(0x1), .size = chunk.len, .pos = 0 };
    const op: c_int = if (finish) ZSTD_e_end else ZSTD_e_flush;
    var scratch: [16 * 1024]u8 = undefined;

    while (true) {
        var out_buf: ZstdOutBuffer = .{ .dst = &scratch, .size = scratch.len, .pos = 0 };
        const remaining = f.ZSTD_compressStream2(state, &out_buf, &in_buf, op);
        if (f.ZSTD_isError(remaining) != 0) return null;
        if (out_buf.pos > 0) {
            out.appendSlice(allocator, scratch[0..out_buf.pos]) catch return null;
        }
        if (remaining == 0 and in_buf.pos >= in_buf.size) break;
    }
    return out.toOwnedSlice(allocator) catch null;
}

pub fn streamDestroy(state: *anyopaque) void {
    if (funcs) |f| _ = f.ZSTD_freeCCtx(state);
}
