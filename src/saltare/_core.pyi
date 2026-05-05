from typing import Any

def version() -> str: ...
def serve(
    app: Any,
    host: str,
    port: int,
    ssl_certfile: str | None,
    ssl_keyfile: str | None,
) -> None: ...
