"""Zero-copy static-file responses via the `saltare.sendfile` ASGI extension.

Run:
    saltare examples.sendfile:app

Then:
    curl http://127.0.0.1:8000/img/logo.png > /tmp/out.png

The server uses the `sendfile(2)` syscall directly from kernel buffer to
socket — file bytes never enter Python. Saves MiBs of app-heap
allocation on every static-asset response. Plain-HTTP only; TLS path
returns 500 (kTLS isn't wired in v1.4).
"""

from __future__ import annotations

import mimetypes
import os
import urllib.parse


# Edit to match your static-asset directory. Anything outside this root
# is rejected with 403 — never trust scope["path"] verbatim against the
# filesystem.
STATIC_ROOT = os.path.abspath(os.environ.get("SALTARE_STATIC_ROOT", "/var/www"))


def _safe_join(path: str) -> str | None:
    """Resolve `path` (URL-decoded) under STATIC_ROOT; return None if it
    escapes the root or doesn't exist."""
    decoded = urllib.parse.unquote(path)
    if decoded.startswith("/"):
        decoded = decoded[1:]
    candidate = os.path.normpath(os.path.join(STATIC_ROOT, decoded))
    if not candidate.startswith(STATIC_ROOT + os.sep):
        return None
    if not os.path.isfile(candidate):
        return None
    return candidate


async def app(scope, receive, send):
    if scope["type"] == "lifespan":
        while True:
            msg = await receive()
            if msg["type"] == "lifespan.startup":
                await send({"type": "lifespan.startup.complete"})
            elif msg["type"] == "lifespan.shutdown":
                await send({"type": "lifespan.shutdown.complete"})
                return
        return

    if scope["method"] not in ("GET", "HEAD"):
        await receive()
        await send({"type": "http.response.start", "status": 405,
                    "headers": [(b"allow", b"GET, HEAD")]})
        await send({"type": "http.response.body", "body": b"", "more_body": False})
        return

    await receive()
    target = _safe_join(scope["path"])
    if target is None:
        await send({"type": "http.response.start", "status": 404,
                    "headers": [(b"content-type", b"text/plain")]})
        await send({"type": "http.response.body", "body": b"not found\n", "more_body": False})
        return

    ctype, _ = mimetypes.guess_type(target)
    headers = [(b"content-type", (ctype or "application/octet-stream").encode("ascii"))]

    # The sendfile extension: saltare opens the file, sets Content-Length
    # from `fstat`, and writes the body via `sendfile(2)`. HEAD strips
    # the body automatically.
    await send({
        "type": "saltare.sendfile",
        "path": target,
        "status": 200,
        "headers": headers,
    })
