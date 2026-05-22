// Thin wrapper over OpenSSL for the v0.9 TLS termination path.
//
// Single-cert / single-key per server. Server-only (no mTLS). No SNI,
// no ALPN, no client cert verification. The OpenSSL state machine handles
// renegotiation and protocol details; we just plumb its WANT_READ /
// WANT_WRITE signals into our epoll interest model.
//
// v1.3 change: OpenSSL is no longer linked at build time. The first
// `newContext()` call `dlopen`s libssl and resolves all symbols via
// `dlsym`. Plain-HTTP deployments therefore don't pay any OpenSSL cost —
// the lib is never mapped into the process. The wheel itself is also
// smaller because auditwheel has no DT_NEEDED entry to vendor.

const std = @import("std");
const builtin = @import("builtin");

const dl = @cImport({
    @cInclude("dlfcn.h");
});

// Opaque types — we never look inside an SSL or SSL_CTX struct, so we
// don't need OpenSSL's headers to typecheck pointer arguments.
pub const Ssl = opaque {};
pub const Ctx = opaque {};
const Method = opaque {};

// Constants we'd previously pulled from `<openssl/ssl.h>`. These are part
// of the OpenSSL ABI and have been stable across 1.0.2 / 1.1 / 3.x.
const SSL_FILETYPE_PEM: c_int = 1;
const TLS1_2_VERSION: c_int = 0x0303;
const SSL_CTRL_SET_MIN_PROTO_VERSION: c_int = 123;
const SSL_CTRL_SET_SESS_CACHE_MODE: c_int = 44;
const SSL_CTRL_SET_SESS_CACHE_SIZE: c_int = 42;
const SSL_SESS_CACHE_SERVER: c_long = 0x0002;
const SSL_ERROR_WANT_READ: c_int = 2;
const SSL_ERROR_WANT_WRITE: c_int = 3;
const SSL_ERROR_SYSCALL: c_int = 5;
const SSL_ERROR_ZERO_RETURN: c_int = 6;

// Function-pointer table. All start as null; `loadFuncs()` populates them
// on first use via dlopen + dlsym. We resolve every function up-front
// once libssl is loaded so subsequent TLS calls are just an indirect call
// (one extra cache miss vs the linked path; negligible).
const Funcs = struct {
    TLS_server_method: *const fn () callconv(.c) ?*Method,
    SSL_CTX_new: *const fn (?*Method) callconv(.c) ?*Ctx,
    SSL_CTX_free: *const fn (*Ctx) callconv(.c) void,
    SSL_CTX_ctrl: *const fn (*Ctx, c_int, c_long, ?*anyopaque) callconv(.c) c_long,
    SSL_CTX_use_certificate_chain_file: *const fn (*Ctx, [*c]const u8) callconv(.c) c_int,
    SSL_CTX_use_PrivateKey_file: *const fn (*Ctx, [*c]const u8, c_int) callconv(.c) c_int,
    SSL_CTX_check_private_key: *const fn (*Ctx) callconv(.c) c_int,
    SSL_CTX_load_verify_locations: *const fn (*Ctx, [*c]const u8, [*c]const u8) callconv(.c) c_int,
    SSL_CTX_set_verify: *const fn (*Ctx, c_int, ?*anyopaque) callconv(.c) void,
    SSL_CTX_set_alpn_protos: *const fn (*Ctx, [*c]const u8, c_uint) callconv(.c) c_int,
    SSL_new: *const fn (*Ctx) callconv(.c) ?*Ssl,
    SSL_free: *const fn (*Ssl) callconv(.c) void,
    SSL_set_fd: *const fn (*Ssl, c_int) callconv(.c) c_int,
    SSL_shutdown: *const fn (*Ssl) callconv(.c) c_int,
    SSL_accept: *const fn (*Ssl) callconv(.c) c_int,
    SSL_read: *const fn (*Ssl, [*]u8, c_int) callconv(.c) c_int,
    SSL_write: *const fn (*Ssl, [*]const u8, c_int) callconv(.c) c_int,
    SSL_pending: *const fn (*Ssl) callconv(.c) c_int,
    SSL_get_error: *const fn (*Ssl, c_int) callconv(.c) c_int,
    SSL_session_reused: *const fn (*Ssl) callconv(.c) c_int,
    SSL_get0_alpn_selected: *const fn (*Ssl, [*c][*c]const u8, [*c]c_uint) callconv(.c) void,
};

const SSL_VERIFY_NONE: c_int = 0x00;
const SSL_VERIFY_PEER: c_int = 0x01;
const SSL_VERIFY_FAIL_IF_NO_PEER_CERT: c_int = 0x02;

var funcs: ?Funcs = null;
var libssl_handle: ?*anyopaque = null;

/// SONAME variants we try in order. Modern systems (Debian/Ubuntu 22+,
/// RHEL 9+, manylinux_2_28) ship libssl.so.3; older long-tail keeps
/// .so.1.1 around. Stop at the first one that loads.
const SONAMES = [_][:0]const u8{
    "libssl.so.3",
    "libssl.so.1.1",
    "libssl.so", // some distros ship the unversioned dev symlink
};

fn loadFuncs() bool {
    if (funcs != null) return true;

    for (SONAMES) |name| {
        const h = dl.dlopen(name.ptr, dl.RTLD_NOW | dl.RTLD_GLOBAL);
        if (h != null) {
            libssl_handle = h;
            break;
        }
    }
    if (libssl_handle == null) return false;

    // Resolve every symbol up front. If any one is missing we treat the
    // whole load as a failure — partial resolution would leak null
    // function pointers into the hot path.
    var f: Funcs = undefined;
    inline for (@typeInfo(Funcs).@"struct".fields) |field| {
        const sym = dl.dlsym(libssl_handle, field.name.ptr);
        if (sym == null) {
            _ = dl.dlclose(libssl_handle);
            libssl_handle = null;
            return false;
        }
        @field(f, field.name) = @ptrCast(@alignCast(sym));
    }
    funcs = f;
    return true;
}

pub const InitError = error{
    LibSslNotFound,
    SslCtxNew,
    LoadCert,
    LoadKey,
    PrivateKeyMismatch,
};

/// Build an `SSL_CTX` configured for serving TLS 1.2+ with the given
/// certificate chain and private key (both PEM-encoded). Caller owns the
/// returned pointer and must free it with `freeContext`.
///
/// Returns `LibSslNotFound` if libssl can't be `dlopen`'d. Plain-HTTP
/// deployments never call this, so the lib is never loaded.
///
/// `session_cache_size` configures OpenSSL's server-side session cache.
/// Zero disables caching (every connection negotiates from scratch).
/// Non-zero enables it; ~20 KiB resident per cached session at peak.
// v1.5: kTLS — kernel TLS offload. With OpenSSL ≥ 3.0, setting
// `SSL_OP_ENABLE_KTLS` on the context tells OpenSSL to push cipher
// state into the kernel after handshake, so subsequent writes go
// straight from kernel buffers to the wire (and `sendfile(2)`
// works on TLS sockets — exactly the gap saltare's v1.4 sendfile
// path had). Plus `SSL_OP_ENABLE_KTLS_TX_ZEROCOPY_SENDFILE` (≥ 3.2)
// avoids a TX copy. Constants are public ABI; safe to hard-code.
const SSL_OP_ENABLE_KTLS: c_long = 0x00000008;
const SSL_OP_ENABLE_KTLS_TX_ZEROCOPY_SENDFILE: c_long = 0x00000010;
const SSL_CTRL_OPTIONS: c_int = 32;

pub fn newContext(
    cert_file: [*c]const u8,
    key_file: [*c]const u8,
    session_cache_size: u32,
    ca_file: [*c]const u8,
    verify_client: bool,
    enable_ktls: bool,
) InitError!*Ctx {
    if (!loadFuncs()) return InitError.LibSslNotFound;
    const f = funcs.?;

    const method = f.TLS_server_method();
    const ctx = f.SSL_CTX_new(method) orelse return InitError.SslCtxNew;
    errdefer f.SSL_CTX_free(ctx);

    // Refuse anything older than TLS 1.2 — TLS 1.0/1.1 are obsolete.
    // SSL_CTX_set_min_proto_version is a macro in the headers; the actual
    // ABI call is SSL_CTX_ctrl with cmd=SET_MIN_PROTO_VERSION.
    _ = f.SSL_CTX_ctrl(ctx, SSL_CTRL_SET_MIN_PROTO_VERSION, TLS1_2_VERSION, null);

    if (session_cache_size > 0) {
        _ = f.SSL_CTX_ctrl(ctx, SSL_CTRL_SET_SESS_CACHE_MODE, SSL_SESS_CACHE_SERVER, null);
        _ = f.SSL_CTX_ctrl(ctx, SSL_CTRL_SET_SESS_CACHE_SIZE, @intCast(session_cache_size), null);
    }

    if (f.SSL_CTX_use_certificate_chain_file(ctx, cert_file) != 1) {
        return InitError.LoadCert;
    }
    if (f.SSL_CTX_use_PrivateKey_file(ctx, key_file, SSL_FILETYPE_PEM) != 1) {
        return InitError.LoadKey;
    }
    if (f.SSL_CTX_check_private_key(ctx) != 1) {
        return InitError.PrivateKeyMismatch;
    }

    // mTLS: load the CA bundle the operator wants to verify clients
    // against. With `verify_client=true` we set
    // `SSL_VERIFY_PEER | SSL_VERIFY_FAIL_IF_NO_PEER_CERT` so any
    // connection without a valid client cert is rejected at handshake.
    if (ca_file != null) {
        if (f.SSL_CTX_load_verify_locations(ctx, ca_file, null) != 1) {
            return InitError.LoadCert;
        }
    }
    if (verify_client) {
        f.SSL_CTX_set_verify(
            ctx,
            SSL_VERIFY_PEER | SSL_VERIFY_FAIL_IF_NO_PEER_CERT,
            null,
        );
    }

    if (enable_ktls) {
        // SSL_CTX_set_options is a macro over SSL_CTX_ctrl with
        // cmd=SSL_CTRL_OPTIONS. Returns the new option mask. We don't
        // care about the return — failure to set on OpenSSL < 3.0
        // (where the bit is 0) is harmless: the option is ignored,
        // OpenSSL falls back to userspace TLS, sendfile-over-TLS keeps
        // returning 500. Zero RAM cost when off.
        const ktls_bits = SSL_OP_ENABLE_KTLS | SSL_OP_ENABLE_KTLS_TX_ZEROCOPY_SENDFILE;
        _ = f.SSL_CTX_ctrl(ctx, SSL_CTRL_OPTIONS, ktls_bits, null);
    }

    // v1.9: HTTP/2 ALPN support. Advertise "h2" so clients can negotiate
    // HTTP/2 via TLS ALPN (RFC 7540 Section 3.3). The wire format is
    // length-prefixed: 0x02 'h' '2'.
    const alpn_proto = "\x02h2";
    _ = f.SSL_CTX_set_alpn_protos(ctx, alpn_proto.ptr, @as(c_uint, alpn_proto.len));

    return ctx;
}

pub fn freeContext(ctx: *Ctx) void {
    funcs.?.SSL_CTX_free(ctx);
}

/// Wrap an accepted client fd in a fresh SSL session bound to `ctx`.
/// Returns null on allocation/setup failure (caller should close the fd).
pub fn newSsl(ctx: *Ctx, fd: c_int) ?*Ssl {
    const f = funcs.?;
    const ssl = f.SSL_new(ctx) orelse return null;
    if (f.SSL_set_fd(ssl, fd) != 1) {
        f.SSL_free(ssl);
        return null;
    }
    return ssl;
}

pub fn freeSsl(ssl: *Ssl) void {
    const f = funcs.?;
    // Best-effort close_notify. We don't wait for the peer's close_notify;
    // the kernel's TCP FIN is sufficient for HTTP semantics.
    _ = f.SSL_shutdown(ssl);
    f.SSL_free(ssl);
}

pub const IoStatus = enum {
    /// I/O made progress (handshake step done, or n bytes read/written).
    ok,
    /// SSL needs to read more bytes from the socket before it can make
    /// progress — caller should wait for EPOLLIN.
    want_read,
    /// SSL needs to write bytes to the socket — caller should wait for
    /// EPOLLOUT (this happens during renegotiation, not just the handshake).
    want_write,
    /// Peer closed the TLS session cleanly (close_notify or TCP EOF).
    closed,
    /// Hard failure. The connection is unusable.
    fatal,
};

pub fn handshake(ssl: *Ssl) IoStatus {
    const f = funcs.?;
    const r = f.SSL_accept(ssl);
    if (r == 1) return .ok;
    return mapError(ssl, r);
}

pub const ReadResult = struct { status: IoStatus, n: usize };

pub fn read(ssl: *Ssl, buf: []u8) ReadResult {
    const f = funcs.?;
    const r = f.SSL_read(ssl, buf.ptr, @intCast(buf.len));
    if (r > 0) return .{ .status = .ok, .n = @intCast(r) };
    return .{ .status = mapError(ssl, r), .n = 0 };
}

pub const WriteResult = struct { status: IoStatus, n: usize };

pub fn write(ssl: *Ssl, buf: []const u8) WriteResult {
    const f = funcs.?;
    const r = f.SSL_write(ssl, buf.ptr, @intCast(buf.len));
    if (r > 0) return .{ .status = .ok, .n = @intCast(r) };
    return .{ .status = mapError(ssl, r), .n = 0 };
}

/// Bytes already decrypted in SSL's internal buffer that haven't been
/// surfaced by `read` yet. Important between keep-alive requests: the next
/// HTTP request may already be in OpenSSL's buffer with no kernel-level
/// readiness event coming, so the caller must drain it explicitly.
pub fn pending(ssl: *Ssl) usize {
    const f = funcs.?;
    const r = f.SSL_pending(ssl);
    if (r < 0) return 0;
    return @intCast(r);
}

/// True iff this SSL handshake reused a cached server-side session
/// instead of doing a full handshake (RFC 5077 tickets / RFC 8446 PSK).
/// Read once after handshake completes for the
/// `saltare_tls_session_reuse_total` counter — observability into how
/// effective the configured `tls_session_cache_size` is.
pub fn sessionReused(ssl: *Ssl) bool {
    const f = funcs orelse return false;
    return f.SSL_session_reused(ssl) != 0;
}

/// v1.9: Return the negotiated ALPN protocol after a successful TLS
/// handshake, or null if no ALPN was negotiated. Typical values: "h2"
/// (HTTP/2) or "http/1.1" (fallback). The returned slice is valid for
/// the lifetime of the SSL object.
pub fn negotiatedAlpn(ssl: *Ssl) ?[]const u8 {
    const f = funcs orelse return null;
    var proto: [*c]const u8 = undefined;
    var proto_len: c_uint = 0;
    f.SSL_get0_alpn_selected(ssl, &proto, &proto_len);
    if (proto_len == 0) return null;
    return proto[0..proto_len];
}

fn mapError(ssl: *Ssl, ret: c_int) IoStatus {
    const f = funcs.?;
    return switch (f.SSL_get_error(ssl, ret)) {
        SSL_ERROR_WANT_READ => .want_read,
        SSL_ERROR_WANT_WRITE => .want_write,
        // ZERO_RETURN: peer sent close_notify. SYSCALL with ret==0 means TCP
        // EOF before close_notify — treat both as closed for HTTP purposes.
        SSL_ERROR_ZERO_RETURN => .closed,
        SSL_ERROR_SYSCALL => .closed,
        else => .fatal,
    };
}
