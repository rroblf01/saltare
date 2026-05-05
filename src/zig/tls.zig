// Thin wrapper over OpenSSL for the v0.9 TLS termination path.
//
// Single-cert / single-key per server. Server-only (no mTLS). No SNI,
// no ALPN, no client cert verification. The OpenSSL state machine handles
// renegotiation and protocol details; we just plumb its WANT_READ /
// WANT_WRITE signals into our epoll interest model.

const std = @import("std");

pub const c = @cImport({
    @cInclude("openssl/ssl.h");
    @cInclude("openssl/err.h");
});

pub const Ssl = c.SSL;
pub const Ctx = c.SSL_CTX;

pub const InitError = error{
    SslCtxNew,
    LoadCert,
    LoadKey,
    PrivateKeyMismatch,
};

/// Build an `SSL_CTX` configured for serving TLS 1.2+ with the given
/// certificate chain and private key (both PEM-encoded). Caller owns the
/// returned pointer and must free it with `freeContext`.
pub fn newContext(cert_file: [*c]const u8, key_file: [*c]const u8) InitError!*Ctx {
    const method = c.TLS_server_method();
    const ctx = c.SSL_CTX_new(method) orelse return InitError.SslCtxNew;
    errdefer c.SSL_CTX_free(ctx);

    // Refuse anything older than TLS 1.2 — TLS 1.0/1.1 are obsolete.
    _ = c.SSL_CTX_set_min_proto_version(ctx, c.TLS1_2_VERSION);

    if (c.SSL_CTX_use_certificate_chain_file(ctx, cert_file) != 1) {
        return InitError.LoadCert;
    }
    if (c.SSL_CTX_use_PrivateKey_file(ctx, key_file, c.SSL_FILETYPE_PEM) != 1) {
        return InitError.LoadKey;
    }
    if (c.SSL_CTX_check_private_key(ctx) != 1) {
        return InitError.PrivateKeyMismatch;
    }

    return ctx;
}

pub fn freeContext(ctx: *Ctx) void {
    c.SSL_CTX_free(ctx);
}

/// Wrap an accepted client fd in a fresh SSL session bound to `ctx`.
/// Returns null on allocation/setup failure (caller should close the fd).
pub fn newSsl(ctx: *Ctx, fd: c_int) ?*Ssl {
    const ssl = c.SSL_new(ctx) orelse return null;
    if (c.SSL_set_fd(ssl, fd) != 1) {
        c.SSL_free(ssl);
        return null;
    }
    return ssl;
}

pub fn freeSsl(ssl: *Ssl) void {
    // Best-effort close_notify. We don't wait for the peer's close_notify;
    // the kernel's TCP FIN is sufficient for HTTP semantics.
    _ = c.SSL_shutdown(ssl);
    c.SSL_free(ssl);
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
    const r = c.SSL_accept(ssl);
    if (r == 1) return .ok;
    return mapError(ssl, r);
}

pub const ReadResult = struct { status: IoStatus, n: usize };

pub fn read(ssl: *Ssl, buf: []u8) ReadResult {
    const r = c.SSL_read(ssl, buf.ptr, @intCast(buf.len));
    if (r > 0) return .{ .status = .ok, .n = @intCast(r) };
    return .{ .status = mapError(ssl, r), .n = 0 };
}

pub const WriteResult = struct { status: IoStatus, n: usize };

pub fn write(ssl: *Ssl, buf: []const u8) WriteResult {
    const r = c.SSL_write(ssl, buf.ptr, @intCast(buf.len));
    if (r > 0) return .{ .status = .ok, .n = @intCast(r) };
    return .{ .status = mapError(ssl, r), .n = 0 };
}

/// Bytes already decrypted in SSL's internal buffer that haven't been
/// surfaced by `read` yet. Important between keep-alive requests: the next
/// HTTP request may already be in OpenSSL's buffer with no kernel-level
/// readiness event coming, so the caller must drain it explicitly.
pub fn pending(ssl: *Ssl) usize {
    const r = c.SSL_pending(ssl);
    if (r < 0) return 0;
    return @intCast(r);
}

fn mapError(ssl: *Ssl, ret: c_int) IoStatus {
    return switch (c.SSL_get_error(ssl, ret)) {
        c.SSL_ERROR_WANT_READ => .want_read,
        c.SSL_ERROR_WANT_WRITE => .want_write,
        // ZERO_RETURN: peer sent close_notify. SYSCALL with ret==0 means TCP
        // EOF before close_notify — treat both as closed for HTTP purposes.
        c.SSL_ERROR_ZERO_RETURN => .closed,
        c.SSL_ERROR_SYSCALL => .closed,
        else => .fatal,
    };
}
