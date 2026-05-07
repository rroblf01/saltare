"""W3C Trace Context propagation + Prometheus latency histogram.

Run:
    saltare examples.observability:app \\
        --metrics-path /metrics \\
        --health-path /healthz \\
        --latency-histogram \\
        --traceparent-propagation

Then:
    curl -H 'traceparent: 00-0af7651916cd43dd8448eb211c80319c-b7ad6b7169203331-01' \\
        http://127.0.0.1:8000/work
    curl http://127.0.0.1:8000/metrics

Look for:
    - response header `traceparent: …` echoed verbatim
    - /metrics body containing
        saltare_request_duration_seconds_bucket{le="0.005"} N
        saltare_request_duration_seconds_sum X.YYYYYY
        saltare_request_duration_seconds_count N
"""

from __future__ import annotations

import asyncio


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

    await receive()

    # Surface the trace context the dispatcher pulled off the request.
    # Apps would normally pass this to OpenTelemetry / their HTTP client
    # so downstream services share the same trace.
    tp = scope.get("traceparent", "")
    ts = scope.get("tracestate", "")

    # Simulate a unit of work — gives the latency histogram something
    # to bucket beyond the first ms.
    await asyncio.sleep(0.012)

    body = (
        f"traceparent: {tp or '(none)'}\n"
        f"tracestate:  {ts or '(none)'}\n"
    ).encode("ascii")

    await send({
        "type": "http.response.start",
        "status": 200,
        "headers": [(b"content-type", b"text/plain")],
    })
    await send({"type": "http.response.body", "body": body, "more_body": False})
