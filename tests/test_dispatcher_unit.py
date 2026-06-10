"""Unit tests for pure-Python functions in _dispatcher.py.

These tests exercise the Python-only functions WITHOUT needing the Zig
native extension (_core). Most test the ASGI dispatcher's header
parsing, wire-format helpers, proxy-header parsing, compression
negotiation, and WebSocket frame helpers.
"""

from __future__ import annotations

import importlib.util
import os
import types
from typing import Any

import pytest


# ---------------------------------------------------------------------------
# Load _dispatcher as a standalone module, bypassing saltare.__init__.py
# (which imports the unavailable _core native extension).
# ---------------------------------------------------------------------------

_SRC_DIR = os.path.join(os.path.dirname(__file__), "..", "src", "saltare")


def _load_dispatcher() -> types.ModuleType:
    path = os.path.join(_SRC_DIR, "_dispatcher.py")
    if os.path.isfile(path):
        spec = importlib.util.spec_from_file_location(
            "saltare._dispatcher_unit_test", path,
        )
        mod = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(mod)
        return mod
    # Fall back to installed package (wheel has _core)
    import saltare._dispatcher as _mod
    return _mod


# Module singleton loaded once per test session
_DISPATCHER = _load_dispatcher()


def _import():
    return _DISPATCHER


def _reset_globals(mod: types.ModuleType) -> None:
    """Restore module-level mutable globals to their defaults."""
    mod._proxy_headers_enabled = False
    mod._request_id_header = None
    mod._server_timing_enabled = False
    mod._gc_collect_every_n = 0
    mod._dispatch_counter = 0
    mod._traceparent_propagation = False
    mod._hsts_header_line = b""
    mod._response_gzip_enabled = False
    mod._response_brotli_enabled = False
    mod._response_zstd_enabled = False
    mod._response_gzip_min_bytes = 512
    mod._response_gzip_level = 6
    mod._response_brotli_quality = 4
    mod._response_zstd_level = 3
    mod._request_decompress_enabled = False
    mod._request_decompress_cap = 1 * 1024 * 1024
    # clear pool between tests
    mod._http_state_pool.clear()


@pytest.fixture(autouse=True)
def _reset():
    mod = _import()
    _reset_globals(mod)
    yield


# ===================================================================
# _parse_accept_encoding
# ===================================================================


class TestParseAcceptEncoding:
    def test_single_encoding(self):
        mod = _import()
        assert mod._parse_accept_encoding(b"gzip") == {b"gzip": 1.0}

    def test_multiple_encodings(self):
        mod = _import()
        result = mod._parse_accept_encoding(b"gzip, br, zstd")
        assert result == {b"gzip": 1.0, b"br": 1.0, b"zstd": 1.0}

    def test_with_quality_weights(self):
        mod = _import()
        result = mod._parse_accept_encoding(b"gzip;q=0.5, br;q=0.8")
        assert result == {b"gzip": 0.5, b"br": 0.8}

    def test_zero_weight_dropped(self):
        mod = _import()
        result = mod._parse_accept_encoding(b"gzip;q=0, br")
        assert result == {b"br": 1.0}

    def test_empty_value(self):
        mod = _import()
        assert mod._parse_accept_encoding(b"") == {}

    def test_malformed_weight_falls_back_to_one(self):
        mod = _import()
        result = mod._parse_accept_encoding(b"gzip;q=abc")
        assert result == {b"gzip": 1.0}

    def test_trailing_semicolon(self):
        mod = _import()
        result = mod._parse_accept_encoding(b"gzip;")
        assert result == {b"gzip": 1.0}

    def test_spaces_around_tokens(self):
        mod = _import()
        result = mod._parse_accept_encoding(b"  gzip  ,  br  ")
        assert result == {b"gzip": 1.0, b"br": 1.0}

    def test_wildcard(self):
        mod = _import()
        result = mod._parse_accept_encoding(b"*")
        assert result == {b"*": 1.0}

    def test_wildcard_with_zero(self):
        mod = _import()
        result = mod._parse_accept_encoding(b"*;q=0")
        assert result == {}

    def test_case_insensitive(self):
        mod = _import()
        result = mod._parse_accept_encoding(b"GZip, BR")
        assert result == {b"gzip": 1.0, b"br": 1.0}


# ===================================================================
# _negotiate_encoding
# ===================================================================


class TestNegotiateEncoding:
    def test_prefers_br_over_zstd_over_gzip_when_equal_weight(self):
        mod = _import()
        mod._response_brotli_enabled = True
        mod._response_zstd_enabled = True
        mod._response_gzip_enabled = True
        result = mod._negotiate_encoding(b"gzip, br, zstd")
        assert result == b"br"

    def test_client_q_overrides_server_preference(self):
        mod = _import()
        mod._response_brotli_enabled = True
        mod._response_zstd_enabled = True
        mod._response_gzip_enabled = True
        result = mod._negotiate_encoding(b"gzip;q=0.9, br;q=0.5, zstd;q=0.8")
        assert result == b"gzip"

    def test_disabled_encoder_not_selected(self):
        mod = _import()
        mod._response_gzip_enabled = True
        mod._response_brotli_enabled = False
        result = mod._negotiate_encoding(b"gzip, br")
        assert result == b"gzip"

    def test_all_disabled_returns_empty(self):
        mod = _import()
        result = mod._negotiate_encoding(b"gzip, br, zstd")
        assert result == b""

    def test_zero_weight_skips(self):
        mod = _import()
        mod._response_gzip_enabled = True
        result = mod._negotiate_encoding(b"gzip;q=0")
        assert result == b""

    def test_wildcard_enables_when_not_explicitly_listed(self):
        mod = _import()
        mod._response_gzip_enabled = True
        result = mod._negotiate_encoding(b"*")
        assert result == b"gzip"

    def test_wildcard_zero_blocks_all(self):
        mod = _import()
        mod._response_gzip_enabled = True
        mod._response_brotli_enabled = True
        result = mod._negotiate_encoding(b"*;q=0")
        assert result == b""

    def test_empty_header(self):
        mod = _import()
        mod._response_gzip_enabled = True
        assert mod._negotiate_encoding(b"") == b""


# ===================================================================
# _is_gzippable_content_type
# ===================================================================


class TestIsGzippableContentType:
    def test_text_html(self):
        mod = _import()
        assert mod._is_gzippable_content_type(b"text/html") is True

    def test_application_json(self):
        mod = _import()
        assert mod._is_gzippable_content_type(b"application/json") is True

    def test_image_png_not_gzippable(self):
        mod = _import()
        assert mod._is_gzippable_content_type(b"image/png") is False

    def test_empty_not_gzippable(self):
        mod = _import()
        assert mod._is_gzippable_content_type(b"") is False

    def test_with_charset_param(self):
        mod = _import()
        assert mod._is_gzippable_content_type(b"text/html; charset=utf-8") is True

    def test_case_insensitive(self):
        mod = _import()
        assert mod._is_gzippable_content_type(b"TEXT/HTML") is True

    def test_application_javascript(self):
        mod = _import()
        assert mod._is_gzippable_content_type(b"application/javascript") is True

    def test_image_svg_xml(self):
        mod = _import()
        assert mod._is_gzippable_content_type(b"image/svg+xml") is True

    def test_application_octet_stream_not_gzippable(self):
        mod = _import()
        assert mod._is_gzippable_content_type(b"application/octet-stream") is False

    def test_whitespace_around_type(self):
        mod = _import()
        assert mod._is_gzippable_content_type(b"  text/html  ") is True


# ===================================================================
# _status_line
# ===================================================================


class TestStatusLine:
    def test_common_code_200(self):
        mod = _import()
        assert mod._status_line(200) == b"HTTP/1.1 200 OK\r\n"

    def test_common_code_404(self):
        mod = _import()
        assert mod._status_line(404) == b"HTTP/1.1 404 Not Found\r\n"

    def test_uncommon_code_falls_back_to_ok(self):
        mod = _import()
        # 103 (Early Hints) is not in _REASONS, so it falls back to "OK"
        assert mod._status_line(103) == b"HTTP/1.1 103 OK\r\n"

    def test_zero_status(self):
        mod = _import()
        result = mod._status_line(0)
        assert b"0" in result

    def test_all_cached_codes(self):
        mod = _import()
        for code in mod._REASONS:
            expected = f"HTTP/1.1 {code} {mod._REASONS[code]}\r\n".encode("ascii")
            assert mod._status_line(code) == expected


# ===================================================================
# _build_wire
# ===================================================================


class TestBuildWire:
    def test_basic_response(self):
        mod = _import()
        result = mod._build_wire(
            200, [(b"content-type", b"text/plain")], b"OK\n", keep_alive=False,
        )
        assert result.startswith(b"HTTP/1.1 200 OK\r\n")
        assert b"connection: close\r\n" in result
        assert b"content-type: text/plain\r\n" in result
        assert b"content-length: 3\r\n" in result
        assert result.endswith(b"\r\n\r\nOK\n")

    def test_keepalive_response(self):
        mod = _import()
        result = mod._build_wire(
            200, [], b"", keep_alive=True,
        )
        assert b"connection: keep-alive\r\n" in result

    def test_content_length_supplied_externally(self):
        mod = _import()
        result = mod._build_wire(
            200, [(b"content-length", b"42")], b"body", keep_alive=False,
        )
        # Must not add a second content-length
        assert result.count(b"content-length:") == 1
        assert b"content-length: 42\r\n" in result

    def test_connection_header_stripped(self):
        mod = _import()
        result = mod._build_wire(
            200, [(b"connection", b"upgrade")], b"", keep_alive=False,
        )
        # Only our own connection: close line should be present
        assert b"connection: close\r\n" in result
        assert b"connection: upgrade\r\n" not in result


# ===================================================================
# _encode_chunk
# ===================================================================


class TestEncodeChunk:
    def test_small_chunk(self):
        mod = _import()
        assert mod._encode_chunk(b"hello") == b"5\r\nhello\r\n"

    def test_large_chunk(self):
        mod = _import()
        body = b"x" * 1000
        assert mod._encode_chunk(body) == b"3e8\r\n" + body + b"\r\n"

    def test_empty_chunk(self):
        mod = _import()
        # Empty input gives "0\r\n\r\n"
        assert mod._encode_chunk(b"") == b"0\r\n\r\n"


# ===================================================================
# _build_server_frame (RFC 6455)
# ===================================================================


class TestBuildServerFrame:
    def test_text_frame_small(self):
        mod = _import()
        frame = mod._build_server_frame(0x1, b"hello")
        assert frame[0] & 0x80  # FIN
        assert (frame[0] & 0x0F) == 0x1  # opcode = text
        assert frame[1] == 5  # payload length
        assert frame[2:] == b"hello"

    def test_binary_frame_medium(self):
        mod = _import()
        payload = b"x" * 200
        frame = mod._build_server_frame(0x2, payload)
        assert (frame[0] & 0x0F) == 0x2
        assert frame[1] == 126  # 16-bit length marker
        assert frame[2:4] == (200).to_bytes(2, "big")

    def test_large_frame(self):
        mod = _import()
        payload = b"x" * 70000
        frame = mod._build_server_frame(0x1, payload)
        assert frame[1] == 127  # 64-bit length marker
        assert frame[2:10] == (70000).to_bytes(8, "big")

    def test_rsv1_flag(self):
        mod = _import()
        frame = mod._build_server_frame(0x1, b"hi", rsv1=True)
        assert frame[0] & 0x40  # RSV1 bit set

    def test_no_rsv1(self):
        mod = _import()
        frame = mod._build_server_frame(0x1, b"hi", rsv1=False)
        assert not (frame[0] & 0x40)  # RSV1 bit not set


# ===================================================================
# _pmd_negotiate
# ===================================================================


class TestPmdNegotiate:
    def test_no_extensions_header(self):
        mod = _import()
        active, response, _st, _ct = mod._pmd_negotiate([])
        assert active is False
        assert response == ""

    def test_unrelated_extension(self):
        mod = _import()
        headers = [(b"sec-websocket-extensions", b"foo-bar")]
        active, response, _st, _ct = mod._pmd_negotiate(headers)
        assert active is False

    def test_permessage_deflate_offered(self):
        mod = _import()
        headers = [(b"sec-websocket-extensions", b"permessage-deflate")]
        active, response, _st, _ct = mod._pmd_negotiate(headers)
        assert active is True
        assert "permessage-deflate" in response
        assert "client_no_context_takeover" in response
        assert "server_no_context_takeover" in response

    def test_permessage_deflate_with_params(self):
        mod = _import()
        headers = [
            (b"sec-websocket-extensions",
             b"permessage-deflate; client_max_window_bits=15")
        ]
        active, response, _st, _ct = mod._pmd_negotiate(headers)
        assert active is True

    def test_multiple_extensions(self):
        mod = _import()
        headers = [(b"sec-websocket-extensions", b"foo, permessage-deflate, bar")]
        active, response, _st, _ct = mod._pmd_negotiate(headers)
        assert active is True

    def test_multiple_header_lines(self):
        mod = _import()
        headers = [
            (b"sec-websocket-extensions", b"foo"),
            (b"sec-websocket-extensions", b"permessage-deflate"),
        ]
        active, response, _st, _ct = mod._pmd_negotiate(headers)
        assert active is True


# ===================================================================
# _pmd_deflate / _pmd_inflate
# ===================================================================


class TestPmdDeflateInflate:
    def test_roundtrip_small_payload(self):
        mod = _import()
        original = b"hello world"
        _, compressed = mod._pmd_deflate(None, original)
        assert compressed != original
        _, decompressed = mod._pmd_inflate(None, compressed)
        assert decompressed == original

    def test_roundtrip_large_payload(self):
        mod = _import()
        original = b"x" * 10000
        _, compressed = mod._pmd_deflate(None, original)
        _, decompressed = mod._pmd_inflate(None, compressed)
        assert decompressed == original

    def test_invalid_compressed_data_returns_none(self):
        mod = _import()
        _, result = mod._pmd_inflate(None, b"garbage data that is not deflate")
        assert result is None

    def test_payload_exceeds_max_size(self):
        mod = _import()
        # Create a payload that inflates to > max_size
        original = b"A" * 2000
        _, compressed = mod._pmd_deflate(None, original)
        _, result = mod._pmd_inflate(None, compressed, max_size=100)
        assert result is None

    def test_compressor_recreated_per_call(self):
        mod = _import()
        _, c1 = mod._pmd_deflate(None, b"msg1")
        _, c2 = mod._pmd_deflate(None, b"msg2")
        # Without context takeover, each call uses a fresh compressor
        # and produces independent output.
        _, d1 = mod._pmd_inflate(None, c1)
        _, d2 = mod._pmd_inflate(None, c2)
        assert d1 == b"msg1"
        assert d2 == b"msg2"


# ===================================================================
# _apply_proxy_headers
# ===================================================================


class TestApplyProxyHeaders:
    def test_no_proxy_headers_no_change(self):
        mod = _import()
        scheme, client, server = mod._apply_proxy_headers(
            [], "http", "127.0.0.1", 8000,
        )
        assert scheme == "http"
        assert client is None
        assert server == ("127.0.0.1", 8000)

    def test_x_forwarded_for(self):
        mod = _import()
        headers = [(b"x-forwarded-for", b"1.2.3.4, 5.6.7.8")]
        scheme, client, server = mod._apply_proxy_headers(
            headers, "http", "127.0.0.1", 8000,
        )
        assert client == ("1.2.3.4", 0)

    def test_x_real_ip_overrides_x_forwarded_for(self):
        mod = _import()
        headers = [
            (b"x-forwarded-for", b"1.2.3.4"),
            (b"x-real-ip", b"5.6.7.8"),
        ]
        scheme, client, server = mod._apply_proxy_headers(
            headers, "http", "127.0.0.1", 8000,
        )
        assert client == ("5.6.7.8", 0)

    def test_forwarded_for_rfc7239_overrides_all(self):
        mod = _import()
        headers = [
            (b"x-forwarded-for", b"1.2.3.4"),
            (b"x-real-ip", b"5.6.7.8"),
            (b"forwarded", b"for=9.10.11.12"),
        ]
        scheme, client, server = mod._apply_proxy_headers(
            headers, "http", "127.0.0.1", 8000,
        )
        assert client == ("9.10.11.12", 0)

    def test_x_forwarded_proto(self):
        mod = _import()
        headers = [(b"x-forwarded-proto", b"https")]
        scheme, client, server = mod._apply_proxy_headers(
            headers, "http", "127.0.0.1", 8000,
        )
        assert scheme == "https"

    def test_forwarded_proto_overrides_xfp_when_both_present(self):
        mod = _import()
        headers = [
            (b"x-forwarded-proto", b"http"),
            (b"forwarded", b"proto=https"),
        ]
        scheme, client, server = mod._apply_proxy_headers(
            headers, "http", "127.0.0.1", 8000,
        )
        assert scheme == "https"

    def test_forwarded_ipv6_with_port(self):
        mod = _import()
        headers = [(b"forwarded", b'for="[::1]:1234"')]
        scheme, client, server = mod._apply_proxy_headers(
            headers, "http", "127.0.0.1", 8000,
        )
        assert client == ("::1", 0)

    def test_forwarded_ipv4_with_port(self):
        mod = _import()
        headers = [(b"forwarded", b"for=192.0.2.1:5678")]
        scheme, client, server = mod._apply_proxy_headers(
            headers, "http", "127.0.0.1", 8000,
        )
        assert client == ("192.0.2.1", 0)

    def test_x_forwarded_host(self):
        mod = _import()
        headers = [(b"x-forwarded-host", b"example.com:8080")]
        scheme, client, server = mod._apply_proxy_headers(
            headers, "http", "127.0.0.1", 8000,
        )
        assert server == ("example.com", 8080)

    def test_forwarded_host_overrides_xfh(self):
        mod = _import()
        headers = [
            (b"x-forwarded-host", b"old.example.com"),
            (b"forwarded", b"host=new.example.com"),
        ]
        scheme, client, server = mod._apply_proxy_headers(
            headers, "http", "127.0.0.1", 8000,
        )
        assert server == ("new.example.com", 8000)

    def test_invalid_utf8_in_proxy_header_ignored(self):
        mod = _import()
        headers = [(b"x-forwarded-for", b"\xff\xfe\x00")]
        scheme, client, server = mod._apply_proxy_headers(
            headers, "http", "127.0.0.1", 8000,
        )
        assert client is None  # ignored due to decode error

    def test_forwarded_proto_not_http_or_https(self):
        mod = _import()
        headers = [(b"forwarded", b"proto=unknown")]
        scheme, client, server = mod._apply_proxy_headers(
            headers, "http", "127.0.0.1", 8000,
        )
        assert scheme == "http"  # unchanged

    def test_forwarded_multiple_values_first_wins(self):
        mod = _import()
        headers = [(b"forwarded", b"for=1.1.1.1, for=2.2.2.2")]
        scheme, client, server = mod._apply_proxy_headers(
            headers, "http", "127.0.0.1", 8000,
        )
        assert client == ("1.1.1.1", 0)

    def test_forwarded_ipv6_without_brackets(self):
        mod = _import()
        headers = [(b"forwarded", b"for=::1")]
        scheme, client, server = mod._apply_proxy_headers(
            headers, "http", "127.0.0.1", 8000,
        )
        assert client == ("::1", 0)


# ===================================================================
# Module-level setter functions
# ===================================================================


class TestSetters:
    def test_set_proxy_headers(self):
        mod = _import()
        assert mod._proxy_headers_enabled is False
        mod.set_proxy_headers(True)
        assert mod._proxy_headers_enabled is True
        mod.set_proxy_headers(0)
        assert mod._proxy_headers_enabled is False

    def test_set_request_id_header(self):
        mod = _import()
        assert mod._request_id_header is None
        mod.set_request_id_header("X-Request-Id")
        assert mod._request_id_header == b"x-request-id"
        mod.set_request_id_header(None)
        assert mod._request_id_header is None
        # Empty string disables
        mod.set_request_id_header("")
        assert mod._request_id_header is None

    def test_set_server_timing(self):
        mod = _import()
        assert mod._server_timing_enabled is False
        mod.set_server_timing(True)
        assert mod._server_timing_enabled is True

    def test_set_gc_collect_every_n_zero_disables(self):
        mod = _import()
        assert mod._gc_collect_every_n == 0
        mod.set_gc_collect_every_n(100)
        assert mod._gc_collect_every_n == 100
        mod.set_gc_collect_every_n(-5)
        assert mod._gc_collect_every_n == 0

    def test_set_server_header_default(self):
        mod = _import()
        old = mod._SERVER_LINE
        mod.set_server_header(None)
        assert mod._SERVER_LINE == old  # unchanged
        mod.set_server_header("Custom/1.0")
        assert mod._SERVER_LINE == b"server: Custom/1.0\r\n"
        mod.set_server_header("")
        assert mod._SERVER_LINE == b""

    def test_set_traceparent_propagation(self):
        mod = _import()
        assert mod._traceparent_propagation is False
        mod.set_traceparent_propagation(True)
        assert mod._traceparent_propagation is True

    def test_set_hsts_disabled_by_zero_max_age(self):
        mod = _import()
        assert mod._hsts_header_line == b""
        mod.set_hsts(31536000, False, False)
        assert b"max-age=31536000" in mod._hsts_header_line
        assert b"strict-transport-security" in mod._hsts_header_line
        mod.set_hsts(0, False, False)
        assert mod._hsts_header_line == b""

    def test_set_hsts_with_subdomains_and_preload(self):
        mod = _import()
        mod.set_hsts(31536000, True, True)
        line = mod._hsts_header_line
        assert b"max-age=31536000" in line
        assert b"includeSubDomains" in line
        assert b"preload" in line

    def test_set_hsts_negative_disables(self):
        mod = _import()
        mod.set_hsts(100, False, False)
        assert mod._hsts_header_line != b""
        mod.set_hsts(-1, False, False)
        assert mod._hsts_header_line == b""


# ===================================================================
# Response compression setters
# ===================================================================


class TestCompressionSetters:
    def test_set_response_gzip_enable(self):
        mod = _import()
        assert mod._response_gzip_enabled is False
        mod.set_response_gzip(True)
        assert mod._response_gzip_enabled is True
        assert mod._response_gzip_level == 6

    def test_set_response_gzip_with_level(self):
        mod = _import()
        mod.set_response_gzip(True, level=3)
        assert mod._response_gzip_level == 3

    def test_set_response_gzip_out_of_range_level(self):
        mod = _import()
        mod.set_response_gzip(True, level=99)  # out of range [1,9]
        assert mod._response_gzip_level == 6  # unchanged

    def test_set_response_gzip_min_bytes(self):
        mod = _import()
        mod.set_response_gzip(True, min_bytes=1024)
        assert mod._response_gzip_min_bytes == 1024

    def test_set_response_brotli(self):
        mod = _import()
        assert mod._response_brotli_enabled is False
        mod.set_response_brotli(True, quality=8)
        assert mod._response_brotli_enabled is True
        assert mod._response_brotli_quality == 8

    def test_set_response_brotli_out_of_range(self):
        mod = _import()
        mod.set_response_brotli(True, quality=50)
        assert mod._response_brotli_quality == 4  # unchanged

    def test_set_response_zstd(self):
        mod = _import()
        assert mod._response_zstd_enabled is False
        mod.set_response_zstd(True, level=10)
        assert mod._response_zstd_enabled is True
        assert mod._response_zstd_level == 10

    def test_set_response_zstd_out_of_range(self):
        mod = _import()
        mod.set_response_zstd(True, level=99)
        assert mod._response_zstd_level == 3  # unchanged

    def test_set_request_decompression(self):
        mod = _import()
        assert mod._request_decompress_enabled is False
        mod.set_request_decompression(True, cap_bytes=65536)
        assert mod._request_decompress_enabled is True
        assert mod._request_decompress_cap == 65536

    def test_set_request_decompression_zero_cap_keeps_existing(self):
        mod = _import()
        mod._request_decompress_cap = 9999
        mod.set_request_decompression(True, cap_bytes=0)
        assert mod._request_decompress_cap == 9999  # unchanged


# ===================================================================
# _ensure_state / thread-local helpers (basic smoke)
# ===================================================================


class TestState:
    def test_ensure_state_creates_loop(self):
        mod = _import()
        state = mod._ensure_state()
        assert hasattr(state, "loop")
        assert state.next_ws_handle >= 1
        assert state.next_http_handle >= 1

    def test_ensure_loop_returns_same_loop(self):
        mod = _import()
        loop1 = mod._ensure_loop()
        loop2 = mod._ensure_loop()
        assert loop1 is loop2

    def test_asgi_state_is_dict(self):
        mod = _import()
        state = mod._ensure_state()
        assert isinstance(state.asgi_state, dict)

    def test_http_state_pool_initially_empty(self):
        mod = _import()
        assert mod._http_state_pool == []


# =================================================================--
# _WsState unit tests (without _core)
# =================================================================--


class TestWsState:
    def test_init_creates_task(self):
        mod = _import()
        scope = {"type": "websocket", "asgi": mod._ASGI_WS_SUB, "path": "/"}
        ws = mod._WsState(_dummy_ws_app, scope)
        assert ws.accepted is False
        assert ws.closed is False
        assert ws.subprotocol == ""
        assert ws.extensions == ""
        assert ws.close_code == 0

    def test_push_and_drain(self):
        mod = _import()
        scope = {"type": "websocket", "asgi": mod._ASGI_WS_SUB, "path": "/"}
        ws = mod._WsState(_dummy_ws_app, scope)
        ws.push({"type": "websocket.connect"})
        drained = ws.drain()
        assert isinstance(drained, bytes)

    def test_drain_empty_returns_empty_bytes(self):
        mod = _import()
        scope = {"type": "websocket", "asgi": mod._ASGI_WS_SUB, "path": "/"}
        ws = mod._WsState(_dummy_ws_app, scope)
        assert ws.drain() == b""


# ===================================================================
# _HttpState unit tests (basic construction without _core)
# ===================================================================


class TestHttpState:
    def test_init_sets_pending_event(self):
        mod = _import()
        scope = {"type": "http", "asgi": mod._ASGI_HTTP_SUB, "method": "GET", "path": "/"}
        s = mod._HttpState(_dummy_http_app, scope, b"", False, True)
        assert s._pending_event is not None
        assert s._pending_event["type"] == "http.request"
        assert s._pending_event["body"] == b""
        assert s._pending_event["more_body"] is False
        assert s.ka is True
        assert s.status == 500

    def test_acquire_and_release_pool(self):
        mod = _import()
        # Drain the pool
        mod._http_state_pool.clear()
        scope = {"type": "http", "asgi": mod._ASGI_HTTP_SUB, "method": "GET", "path": "/"}
        s = mod._acquire_http_state(_dummy_http_app, scope, b"", False, True)
        assert s is not None
        mod._release_http_state(s)
        assert len(mod._http_state_pool) == 1
        # Acquire from pool
        s2 = mod._acquire_http_state(_dummy_http_app, scope, b"", False, False)
        assert s2 is s  # same object
        assert s2.ka is False  # reset

    def test_reset_clears_state(self):
        mod = _import()
        scope = {"type": "http", "asgi": mod._ASGI_HTTP_SUB, "method": "GET", "path": "/"}
        s = mod._HttpState(_dummy_http_app, scope, b"init", True, True)
        s.status = 999
        s.outgoing.append(b"stale data")
        s.reset(_dummy_http_app, scope, b"new", False, False)
        assert s.status == 500  # reset to default
        assert s._pending_event["body"] == b"new"
        assert s.ka is False

    def test_push_body_sets_pending_event(self):
        mod = _import()
        scope = {"type": "http", "asgi": mod._ASGI_HTTP_SUB, "method": "POST", "path": "/"}
        s = mod._HttpState(_dummy_http_app, scope, b"", True, True)
        s.push_body(b"more data", False)
        assert s._pending_event["body"] == b"more data"
        assert s._pending_event["more_body"] is False

    def test_push_disconnect(self):
        mod = _import()
        scope = {"type": "http", "asgi": mod._ASGI_HTTP_SUB, "method": "GET", "path": "/"}
        s = mod._HttpState(_dummy_http_app, scope, b"", False, True)
        s.push_disconnect()
        assert s._pending_event["type"] == "http.disconnect"

    def test_emit_headers_no_streaming(self):
        mod = _import()
        scope = {"type": "http", "asgi": mod._ASGI_HTTP_SUB, "method": "GET", "path": "/"}
        s = mod._HttpState(_dummy_http_app, scope, b"", False, True)
        s.status = 201
        s._emit_headers(streaming=False, complete_body_len=42)
        out = b"".join(s.outgoing)
        assert b"HTTP/1.1 201 Created\r\n" in out
        assert b"content-length: 42\r\n" in out
        assert b"connection: keep-alive\r\n" in out
        assert b"transfer-encoding:" not in out

    def test_emit_headers_streaming_chunked(self):
        mod = _import()
        scope = {"type": "http", "asgi": mod._ASGI_HTTP_SUB, "method": "GET", "path": "/"}
        s = mod._HttpState(_dummy_http_app, scope, b"", False, True)
        s.status = 200
        s._emit_headers(streaming=True, complete_body_len=None)
        out = b"".join(s.outgoing)
        assert b"transfer-encoding: chunked\r\n" in out
        assert s.chunked is True

    def test_emit_headers_streaming_with_explicit_cl(self):
        mod = _import()
        scope = {"type": "http", "asgi": mod._ASGI_HTTP_SUB, "method": "GET", "path": "/"}
        s = mod._HttpState(_dummy_http_app, scope, b"", False, True)
        s.status = 200
        s.explicit_cl = True
        s._emit_headers(streaming=True, complete_body_len=100)
        out = b"".join(s.outgoing)
        assert b"transfer-encoding:" not in out
        assert s.chunked is False

    def test_emit_headers_request_id(self):
        mod = _import()
        old_id_header = mod._request_id_header
        mod._request_id_header = b"x-request-id"
        scope = {"type": "http", "asgi": mod._ASGI_HTTP_SUB, "method": "GET", "path": "/"}
        s = mod._HttpState(_dummy_http_app, scope, b"", False, True)
        s._request_id = b"abc123"
        s._emit_headers(streaming=False, complete_body_len=0)
        mod._request_id_header = old_id_header
        out = b"".join(s.outgoing)
        assert b"x-request-id: abc123\r\n" in out

    def test_emit_headers_hsts(self):
        mod = _import()
        mod._hsts_header_line = b"strict-transport-security: max-age=3600\r\n"
        scope = {"type": "http", "asgi": mod._ASGI_HTTP_SUB, "method": "GET", "path": "/"}
        s = mod._HttpState(_dummy_http_app, scope, b"", False, True)
        s._emit_headers(streaming=False, complete_body_len=0)
        out = b"".join(s.outgoing)
        assert b"strict-transport-security: max-age=3600\r\n" in out
        mod._hsts_header_line = b""

    def test_emit_headers_traceparent(self):
        mod = _import()
        scope = {"type": "http", "asgi": mod._ASGI_HTTP_SUB, "method": "GET", "path": "/"}
        s = mod._HttpState(_dummy_http_app, scope, b"", False, True)
        s._traceparent_echo = b"00-abc-xyz-01"
        s._emit_headers(streaming=False, complete_body_len=0)
        out = b"".join(s.outgoing)
        assert b"traceparent: 00-abc-xyz-01\r\n" in out

    def test_finalize_no_headers_sent(self):
        mod = _import()
        scope = {"type": "http", "asgi": mod._ASGI_HTTP_SUB, "method": "GET", "path": "/"}
        s = mod._HttpState(_dummy_http_app, scope, b"", False, True)
        extra = mod._finalize_if_needed(0, s)
        # Should return a 500 wire response
        assert b"500" in extra

    def test_finalize_chunked_without_body_done(self):
        mod = _import()
        scope = {"type": "http", "asgi": mod._ASGI_HTTP_SUB, "method": "GET", "path": "/"}
        s = mod._HttpState(_dummy_http_app, scope, b"", False, True)
        s.headers_sent = True
        s.chunked = True
        extra = mod._finalize_if_needed(0, s)
        assert extra == b"0\r\n\r\n"

    def test_finalize_trailer_started(self):
        mod = _import()
        scope = {"type": "http", "asgi": mod._ASGI_HTTP_SUB, "method": "GET", "path": "/"}
        s = mod._HttpState(_dummy_http_app, scope, b"", False, True)
        s.headers_sent = True
        s.chunked = True
        s._trailer_started = True
        extra = mod._finalize_if_needed(0, s)
        assert extra == b"\r\n"

    def test_finalize_none_needed(self):
        mod = _import()
        scope = {"type": "http", "asgi": mod._ASGI_HTTP_SUB, "method": "GET", "path": "/"}
        s = mod._HttpState(_dummy_http_app, scope, b"", False, True)
        s.headers_sent = True
        s.body_done = True
        extra = mod._finalize_if_needed(0, s)
        assert extra == b""


# ===================================================================
# _set_ws_upgrade_deadline
# ===================================================================


class TestWsUpgradeDeadline:
    def test_default_value(self):
        mod = _import()
        assert mod._WS_UPGRADE_DEADLINE_S == 2.0

    def test_set_positive(self):
        mod = _import()
        mod.set_ws_upgrade_deadline(5.0)
        assert mod._WS_UPGRADE_DEADLINE_S == 5.0

    def test_set_zero_reverts_to_default(self):
        mod = _import()
        mod.set_ws_upgrade_deadline(0)
        assert mod._WS_UPGRADE_DEADLINE_S == 2.0

    def test_set_negative_reverts_to_default(self):
        mod = _import()
        mod.set_ws_upgrade_deadline(-1)
        assert mod._WS_UPGRADE_DEADLINE_S == 2.0


# ===================================================================
# Dummy ASGI apps for tests that don't need _core
# ===================================================================


async def _dummy_ws_app(scope, receive, send):
    """Minimal WS app that loops until disconnect."""
    while True:
        msg = await receive()
        if msg["type"] == "websocket.disconnect":
            break
        elif msg["type"] == "websocket.connect":
            await send({"type": "websocket.accept"})


async def _dummy_http_app(scope, receive, send):
    """Minimal HTTP app."""
    await receive()
    await send({
        "type": "http.response.start",
        "status": 200,
        "headers": [(b"content-type", b"text/plain")],
    })
    await send({"type": "http.response.body", "body": b"ok"})


# ===================================================================
# lifespan_startup protocol handling (v1.10)
# ===================================================================


class TestLifespanStartup:
    def test_startup_complete_returns_true(self):
        mod = _import()

        async def app(scope, receive, send):
            assert scope["type"] == "lifespan"
            assert (await receive())["type"] == "lifespan.startup"
            await send({"type": "lifespan.startup.complete"})
            await receive()  # park awaiting shutdown

        assert mod.lifespan_startup(app) is True

    def test_startup_failed_returns_false(self):
        mod = _import()

        async def app(scope, receive, send):
            await receive()
            await send({"type": "lifespan.startup.failed", "message": "boom"})

        assert mod.lifespan_startup(app) is False

    def test_unexpected_startup_message_is_lenient(self):
        """An app that doesn't check scope["type"] and replies with an
        unexpected message (e.g. http.response.start during lifespan) is
        treated as 'not lifespan-aware' — saltare logs it and keeps serving
        (uvicorn lifespan="auto" semantics), rather than refusing to boot."""
        mod = _import()

        async def app(scope, receive, send):
            await receive()
            await send({"type": "http.response.start", "status": 200, "headers": []})

        assert mod.lifespan_startup(app) is True
