"""Minimal Channels consumer for the saltare smoke example.

Accepts every incoming WebSocket connection, echoes back any text
frame it receives, and logs a tag so you can correlate lines in
`--access-log` output. Real apps will:
  - inspect `self.scope["user"]` (populated by AuthMiddlewareStack)
  - `await self.close(code=4001)` on auth failure (saltare maps to 401)
  - `await self.channel_layer.group_add(...)` to receive group_send fanout
  - dispatch on `text_data` / `bytes_data` shape
"""

import logging

from channels.generic.websocket import AsyncWebsocketConsumer

logger = logging.getLogger("saltare.example.channels")


class EchoConsumer(AsyncWebsocketConsumer):
    async def connect(self):
        # The scope is now the standard ASGI 3.0 shape (v1.7.0):
        #   - scope["state"] is the shared lifespan-state dict
        #   - scope["extensions"] is present (empty)
        #   - scope["client"] reflects the real peer when --proxy-headers is on
        logger.info(
            "ws-connect path=%s client=%s user=%s",
            self.scope.get("path"),
            self.scope.get("client"),
            self.scope.get("user"),
        )
        await self.accept()
        # Initial server-push happens here — saltare v1.7.1's post-accept
        # pump phase lets these awaits run BEFORE returning control to
        # the bridge, so the client sees the welcome frame on the same
        # tick as the 101 upgrade response.
        await self.send(text_data="welcome")

    async def disconnect(self, close_code: int) -> None:
        logger.info(
            "ws-disconnect path=%s code=%s",
            self.scope.get("path"),
            close_code,
        )

    async def receive(self, text_data: str | None = None, bytes_data: bytes | None = None) -> None:
        if text_data is not None:
            await self.send(text_data=f"echo: {text_data}")
        elif bytes_data is not None:
            await self.send(bytes_data=bytes_data)
