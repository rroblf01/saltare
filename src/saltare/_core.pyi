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
) -> None: ...
