"""Negotiated content-encoding (gzip + brotli + zstd) end-to-end.

Run:
    saltare examples.compression:app \\
        --response-gzip --response-brotli --response-zstd \\
        --request-decompression

Then:
    curl -H 'Accept-Encoding: br' http://127.0.0.1:8000/large --compressed
    curl -H 'Accept-Encoding: zstd' http://127.0.0.1:8000/large --compressed
    curl -H 'Accept-Encoding: gzip' http://127.0.0.1:8000/stream --compressed

Server preference is br > zstd > gzip when the client offers multiple
with equal q-weight. Streaming endpoints (`more_body=True`) only
compress under gzip in v1.4 — brotli + zstd are single-shot.
"""

from __future__ import annotations

# A long, repetitive JSON-ish payload — gzip / brotli / zstd shrink
# this 5–10× depending on the encoder.
LARGE_BODY = (b'{"items": [' + b'"x" * 100,' * 1000 + b'"end"]}')


async def app(scope, receive, send):
    if scope["type"] == "lifespan":
        # Drain lifespan startup / shutdown without state.
        while True:
            msg = await receive()
            if msg["type"] == "lifespan.startup":
                await send({"type": "lifespan.startup.complete"})
            elif msg["type"] == "lifespan.shutdown":
                await send({"type": "lifespan.shutdown.complete"})
                return
        return

    # Drain the request body. POSTed bodies with `Content-Encoding:
    # gzip` are decompressed by saltare before this `receive()` if
    # `--request-decompression` is on; you'll see the plain bytes.
    body = b""
    while True:
        evt = await receive()
        body += evt.get("body", b"") or b""
        if not evt.get("more_body", False):
            break

    path = scope["path"]
    if path == "/stream":
        # Streaming: more_body=True triggers chunked transfer-encoding
        # + (under --response-gzip) per-chunk Z_SYNC_FLUSH gzip.
        await send({
            "type": "http.response.start", "status": 200,
            "headers": [(b"content-type", b"application/json")],
        })
        for _ in range(5):
            await send({
                "type": "http.response.body",
                "body": LARGE_BODY,
                "more_body": True,
            })
        await send({"type": "http.response.body", "body": b"", "more_body": False})
        return

    if path == "/large":
        # Single-shot: saltare picks the best enabled encoder from the
        # client's Accept-Encoding (br > zstd > gzip).
        await send({
            "type": "http.response.start", "status": 200,
            "headers": [(b"content-type", b"application/json")],
        })
        await send({
            "type": "http.response.body",
            "body": LARGE_BODY,
            "more_body": False,
        })
        return

    await send({
        "type": "http.response.start", "status": 200,
        "headers": [(b"content-type", b"text/plain")],
    })
    await send({
        "type": "http.response.body",
        "body": b"try /large or /stream\n",
        "more_body": False,
    })
