from typing import Any

def version() -> str: ...
def serve(
    app: Any,
    host: str,
    port: int,
    ssl_certfile: str | None,
    ssl_keyfile: str | None,
    header_timeout: int = ...,
    keep_alive_timeout: int = ...,
    body_timeout: int = ...,
    write_timeout: int = ...,
    max_concurrent_connections: int = ...,
    max_keepalive_requests: int = ...,
    max_request_body: int = ...,
    shutdown_timeout: int = ...,
    uds_path: str | None = ...,
    metrics_path: str | None = ...,
    access_log: int = ...,
    ws_keepalive_timeout: int = ...,
    workers: int = ...,
    health_path: str | None = ...,
    cors_preflight_allow_all: int = ...,
    rate_limit_per_sec: int = ...,
    rate_limit_burst: int = ...,
    tracemalloc_path: str | None = ...,
    proxy_headers: int = ...,
    favicon_204: int = ...,
    max_connections_per_ip: int = ...,
    access_log_path: str | None = ...,
    listen_backlog: int = ...,
    tcp_keepidle: int = ...,
    tcp_keepintvl: int = ...,
    tcp_keepcnt: int = ...,
    proxy_protocol: int = ...,
    tcp_user_timeout_ms: int = ...,
    auto_raise_nofile: int = ...,
    max_connection_lifetime: int = ...,
    tls_session_cache_size: int = ...,
    startup_request: int = ...,
    server_header: str | None = ...,
    ssl_ca_file: str | None = ...,
    ssl_verify_client: int = ...,
    tcp_fastopen_qlen: int = ...,
    gc_collect_every_n_requests: int = ...,
    max_request_uri: int = ...,
    max_request_head_bytes: int = ...,
    latency_histogram: int = ...,
) -> None: ...

# v1.4 lazy-dlopen codec helpers. All four return None when the
# corresponding shared library can't be loaded (musl images without
# libbrotli/libzstd, manylinux without libz, etc.) so callers can
# fall back gracefully.
def gzip_encode(payload: bytes, level: int = 6) -> bytes | None: ...
def gunzip(payload: bytes, max_size: int) -> bytes | None: ...
def brotli_encode(payload: bytes, quality: int = 4) -> bytes | None: ...
def brotli_decode(payload: bytes, max_size: int) -> bytes | None: ...
def zstd_encode(payload: bytes, level: int = 3) -> bytes | None: ...
def zstd_decode(payload: bytes, max_size: int) -> bytes | None: ...
