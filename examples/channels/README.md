# Django Channels under saltare

A minimum-viable Channels app you can run under saltare (v1.7.1+) the
same way you'd run it under daphne. The point of this example is to
verify your local setup end-to-end before plugging saltare into a real
project.

## Setup

```bash
pip install saltare django channels
```

## Run

From this directory:

```bash
saltare asgi:application --host 127.0.0.1 --port 8000 \
    --access-log --ws-reject-log
```

The startup banner should show:

```
saltare reload: watching ... file(s)
info: saltare listening on 127.0.0.1:8000
```

The `lifespan task raised during startup (ValueError: No application
configured for scope type 'lifespan')` line that Channels users saw
in v1.7.0 is silenced in v1.7.1 (it's the documented Channels pattern,
not an error).

## Test the WebSocket

```bash
# Open one terminal:
python -m websockets ws://127.0.0.1:8000/ws/echo/
> hello
< echo: hello

# Or with curl-style verification:
curl -i --no-buffer \
     -H "Connection: Upgrade" \
     -H "Upgrade: websocket" \
     -H "Sec-WebSocket-Key: dGVzdA==" \
     -H "Sec-WebSocket-Version: 13" \
     http://127.0.0.1:8000/ws/echo/
# → HTTP/1.1 101 Switching Protocols
```

The access log shows:

```
19/05/2026:11:46:30 [WS-CONNECT] [/ws/echo/] [101] [0]
19/05/2026:11:48:15 [WS-CLOSE]   [/ws/echo/] [1000] [42]
```

## Files

- [`settings.py`](settings.py) — minimum Django settings (no DB, no admin).
- [`asgi.py`](asgi.py) — `ProtocolTypeRouter` + `AuthMiddlewareStack` +
  `URLRouter`. Same shape Channels' own docs recommend.
- [`consumers.py`](consumers.py) — an `AsyncWebsocketConsumer` that
  accepts every connection and echoes back text frames. Real apps
  will gate on `self.scope["user"]`.

## What this exercises

- saltare's WS upgrade pump (v1.7.1 multi-tick) — handles
  `AuthMiddlewareStack` parking on session lookup.
- ASGI 3.0 `scope["state"]` + `scope["extensions"]` (v1.7.0).
- WS-CONNECT / WS-CLOSE access-log lines (v1.7.1).

If you see HTTP 403 instead of 101 on the upgrade, enable
`--ws-reject-log` and check the close code — usually `4003`
(Origin rejected by `AllowedHostsOriginValidator`) or `4001`
(unauthorised). Adjust `ALLOWED_HOSTS` accordingly.
