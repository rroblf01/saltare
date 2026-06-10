"""Tests for WebSocket permessage-deflate compression.

v1.10 updates the low-level codec contract:
- `_pmd_negotiate` returns (active, token, server_takeover, client_takeover).
- `_pmd_deflate` returns (compressor, bytes); the caller persists the
  compressor when context takeover is negotiated.
- `_pmd_inflate` returns (decompressor, bytes | None).

The headline regression covered here: with server context-takeover enabled,
the server must actually maintain its deflater across messages AND echo a
token that tells the client to do the same — otherwise the client's
persistent inflater desyncs and decode fails from the second message on.
"""

from __future__ import annotations

import importlib.util
import os
import zlib

import pytest


# Load _dispatcher as standalone module, falling back to installed package
_SRC = os.path.join(os.path.dirname(__file__), "..", "src", "saltare", "_dispatcher.py")
if os.path.exists(_SRC):
    _spec = importlib.util.spec_from_file_location("_dispatcher_test", _SRC)
    mod = importlib.util.module_from_spec(_spec)
    _spec.loader.exec_module(mod)
else:
    import saltare._dispatcher as mod

_PMD_TRAIL = mod._PMD_TRAIL


@pytest.fixture(autouse=True)
def _reset_pmd_config():
    """Every test starts from the documented defaults (both takeovers off)."""
    mod.set_ws_compression(level=6, server_takeover=False, client_takeover=False)
    yield
    mod.set_ws_compression(level=6, server_takeover=False, client_takeover=False)


class TestPmdNegotiate:
    def test_no_extensions(self):
        active, token, st, ct = mod._pmd_negotiate([])
        assert active is False
        assert token == ""

    def test_permessage_deflate_offered_default(self):
        headers = [(b"sec-websocket-extensions", b"permessage-deflate")]
        active, token, st, ct = mod._pmd_negotiate(headers)
        assert active is True
        # Default config resets both directions.
        assert st is False and ct is False
        assert "server_no_context_takeover" in token
        assert "client_no_context_takeover" in token

    def test_server_takeover_token_matches_behaviour(self):
        """REGRESSION: with server takeover on and the client not forbidding
        it, the echoed token must NOT carry server_no_context_takeover, and
        the negotiated server_takeover flag must be True. Previously the
        token claimed takeover while the codec reset every message."""
        mod.set_ws_compression(level=6, server_takeover=True, client_takeover=False)
        headers = [(b"sec-websocket-extensions", b"permessage-deflate")]
        active, token, st, ct = mod._pmd_negotiate(headers)
        assert active is True
        assert st is True
        assert "server_no_context_takeover" not in token

    def test_client_forbidding_server_takeover_is_honoured(self):
        mod.set_ws_compression(level=6, server_takeover=True, client_takeover=False)
        headers = [(b"sec-websocket-extensions",
                    b"permessage-deflate; server_no_context_takeover")]
        active, token, st, ct = mod._pmd_negotiate(headers)
        assert active is True
        assert st is False  # client forbade it → we must reset
        assert "server_no_context_takeover" in token

    def test_client_takeover_token(self):
        mod.set_ws_compression(level=6, server_takeover=False, client_takeover=True)
        headers = [(b"sec-websocket-extensions", b"permessage-deflate")]
        active, token, st, ct = mod._pmd_negotiate(headers)
        assert ct is True
        assert "client_no_context_takeover" not in token


class TestPmdDeflateInflate:
    def test_deflate_returns_compressor_and_round_trips(self):
        payload = b"Hello World" * 10
        co, compressed = mod._pmd_deflate(None, payload, reuse_compressor=False)
        assert co is not None
        assert compressed != payload
        _, inflated = mod._pmd_inflate(None, compressed, reuse_decompressor=False)
        assert inflated == payload

    def test_server_takeover_stream_round_trips_across_messages(self):
        """REGRESSION for the dropped-context bug. A server that negotiated
        context takeover persists its deflater; a context-takeover client
        decodes the whole stream with one persistent inflater. If the
        deflater were recreated each message (the old bug), message #2 would
        fail to decode against the persistent inflater."""
        msgs = [b"the quick brown fox", b"the quick brown fox jumps", b"lazy dog" * 5]
        deflater = None
        inflater = None
        for m in msgs:
            deflater, wire = mod._pmd_deflate(deflater, m, reuse_compressor=True)
            inflater, got = mod._pmd_inflate(inflater, wire, reuse_decompressor=True)
            assert got == m

    def test_no_takeover_each_message_is_independent(self):
        # With takeover off, every message uses a fresh decompressor and must
        # still decode (each frame is a self-contained deflate block).
        for m in (b"alpha", b"beta", b"gamma"):
            _, wire = mod._pmd_deflate(None, m, reuse_compressor=False)
            _, got = mod._pmd_inflate(None, wire, reuse_decompressor=False)
            assert got == m

    def test_inflate_exceeds_max_size(self):
        payload = b"A" * 10000
        _, wire = mod._pmd_deflate(None, payload, reuse_compressor=False)
        _, result = mod._pmd_inflate(None, wire, reuse_decompressor=False, max_size=100)
        assert result is None

    def test_inflate_invalid_data(self):
        _, result = mod._pmd_inflate(None, b"invalid compressed data")
        assert result is None


class TestWsCompressionConfig:
    def test_default_level(self):
        assert mod._PMD_LEVEL == 6

    def test_set_compression_level(self):
        mod.set_ws_compression(level=9, server_takeover=False, client_takeover=False)
        assert mod._PMD_LEVEL == 9

    def test_out_of_range_level_ignored(self):
        old_level = mod._PMD_LEVEL
        mod.set_ws_compression(level=99, server_takeover=False, client_takeover=False)
        assert mod._PMD_LEVEL == old_level
        mod.set_ws_compression(level=0, server_takeover=False, client_takeover=False)
        assert mod._PMD_LEVEL == old_level


if __name__ == "__main__":
    pytest.main([__file__, "-v"])
