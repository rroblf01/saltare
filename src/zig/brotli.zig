// Lazy-loaded libbrotli for v1.4 response compression. Same dlopen
// pattern as `zlib.zig` / `tls.zig`: plain-HTTP / non-brotli deployments
// never load libbrotlienc / libbrotlidec, so the wheel doesn't vendor them
// and the process doesn't pay the lib mappings.

const std = @import("std");

const dl = @cImport({
    @cInclude("dlfcn.h");
});

// Symbols we use from libbrotlienc + libbrotlidec.
const Funcs = struct {
    BrotliEncoderMaxCompressedSize: *const fn (usize) callconv(.c) usize,
    BrotliEncoderCompress: *const fn (c_int, c_int, c_int, usize, [*]const u8, *usize, [*]u8) callconv(.c) c_int,
    BrotliDecoderDecompress: *const fn (usize, [*]const u8, *usize, [*]u8) callconv(.c) c_int,
};

var funcs: ?Funcs = null;
var enc_handle: ?*anyopaque = null;
var dec_handle: ?*anyopaque = null;

const ENC_SONAMES = [_][:0]const u8{
    "libbrotlienc.so.1",
    "libbrotlienc.so",
};
const DEC_SONAMES = [_][:0]const u8{
    "libbrotlidec.so.1",
    "libbrotlidec.so",
};

// Brotli quality 0..11; 4-6 is the gzip-equivalent sweet spot for
// HTTP responses. mode 0 = generic, 1 = text, 2 = font.
pub const DEFAULT_QUALITY: c_int = 4;
pub const DEFAULT_LGWIN: c_int = 22;
pub const MODE_GENERIC: c_int = 0;
pub const MODE_TEXT: c_int = 1;

const BROTLI_DECODER_RESULT_SUCCESS: c_int = 1;

fn loadFuncs() bool {
    if (funcs != null) return true;
    for (ENC_SONAMES) |name| {
        const h = dl.dlopen(name.ptr, dl.RTLD_NOW | dl.RTLD_GLOBAL);
        if (h != null) {
            enc_handle = h;
            break;
        }
    }
    if (enc_handle == null) return false;
    for (DEC_SONAMES) |name| {
        const h = dl.dlopen(name.ptr, dl.RTLD_NOW | dl.RTLD_GLOBAL);
        if (h != null) {
            dec_handle = h;
            break;
        }
    }
    if (dec_handle == null) {
        _ = dl.dlclose(enc_handle);
        enc_handle = null;
        return false;
    }
    var f: Funcs = undefined;
    inline for (@typeInfo(Funcs).@"struct".fields) |field| {
        // Encoder symbols live in libbrotlienc; decoder symbols in
        // libbrotlidec. We try both handles and keep whichever resolves.
        const enc_sym = dl.dlsym(enc_handle, field.name.ptr);
        const dec_sym = dl.dlsym(dec_handle, field.name.ptr);
        const sym = if (enc_sym != null) enc_sym else dec_sym;
        if (sym == null) {
            _ = dl.dlclose(enc_handle);
            _ = dl.dlclose(dec_handle);
            enc_handle = null;
            dec_handle = null;
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

/// One-shot brotli compress. `quality` 0..11 (negative → DEFAULT_QUALITY).
/// Returns caller-owned bytes or null on libbrotlienc miss / encoder error.
pub fn brotliEncode(src: []const u8, allocator: std.mem.Allocator, quality: c_int) ?[]u8 {
    if (!loadFuncs()) return null;
    const f = funcs.?;
    const q: c_int = if (quality < 0) DEFAULT_QUALITY else quality;
    const max_out = f.BrotliEncoderMaxCompressedSize(src.len);
    if (max_out == 0) return null;
    const buf = allocator.alloc(u8, max_out) catch return null;
    var encoded_size: usize = max_out;
    const rc = f.BrotliEncoderCompress(
        q,
        DEFAULT_LGWIN,
        MODE_GENERIC,
        src.len,
        src.ptr,
        &encoded_size,
        buf.ptr,
    );
    if (rc == 0) {
        allocator.free(buf);
        return null;
    }
    if (encoded_size == max_out) return buf;
    return allocator.realloc(buf, encoded_size) catch buf[0..encoded_size];
}

/// One-shot brotli decompress with `max_size` cap (zip-bomb defense).
/// Returns caller-owned bytes or null on libbrotlidec miss / overflow /
/// invalid stream.
pub fn brotliDecode(src: []const u8, allocator: std.mem.Allocator, max_size: usize) ?[]u8 {
    if (!loadFuncs()) return null;
    const f = funcs.?;
    // Brotli has no reliable upfront size oracle; start at 4× src and
    // grow if the decoder returns "more output" — but BrotliDecoderDecompress
    // is one-shot, so we just allocate up to the cap and try. If the
    // decoded output exceeds the cap, return null.
    const buf = allocator.alloc(u8, max_size) catch return null;
    var out_size: usize = max_size;
    const rc = f.BrotliDecoderDecompress(src.len, src.ptr, &out_size, buf.ptr);
    if (rc != BROTLI_DECODER_RESULT_SUCCESS) {
        allocator.free(buf);
        return null;
    }
    return allocator.realloc(buf, out_size) catch buf[0..out_size];
}
