// Lazy-loaded libzstd for v1.4 response compression. Same dlopen
// pattern as `zlib.zig`. Plain-HTTP / non-zstd deployments never load
// libzstd, so the wheel doesn't vendor it and the process doesn't pay
// the lib mapping.

const std = @import("std");

const dl = @cImport({
    @cInclude("dlfcn.h");
});

// zstd public ABI: stable across 1.x. We only use the simple one-shot API.
const Funcs = struct {
    ZSTD_compressBound: *const fn (usize) callconv(.c) usize,
    ZSTD_compress: *const fn ([*]u8, usize, [*]const u8, usize, c_int) callconv(.c) usize,
    ZSTD_isError: *const fn (usize) callconv(.c) c_uint,
    ZSTD_getFrameContentSize: *const fn ([*]const u8, usize) callconv(.c) c_ulonglong,
    ZSTD_decompress: *const fn ([*]u8, usize, [*]const u8, usize) callconv(.c) usize,
};

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
