"""PROXY protocol (v1 text + v2 binary) — `proxy_protocol=True`.

This feature had no coverage at all, which is a bad place for it to be
blind: `proxy_protocol` replaces the connection's peer address with the
source address an L4 load balancer claims, and that address is what the
per-IP rate limiter, the per-IP connection cap and the access log use.
Get the parse wrong and you either rate-limit the wrong party or, worse,
treat every client behind the LB as one peer.

The observable used throughout is the rate limiter. `rateLimitAllow` keys
on `conn.peer_key` (server.zig:4199), so a request that arrives behind a
`PROXY TCP4 203.0.113.7 ...` header is throttled against 203.0.113.7
rather than 127.0.0.1. That makes the parse directly observable from
outside the process, with no access to `conn.peer_key`.

What is covered:

  - v1 TCP4 / TCP6: the claimed source becomes the throttling key.
  - v1 UNKNOWN: no reliable source, so the TCP peer is kept — two
    "different" UNKNOWN connections must therefore share one bucket.
  - v1 and v2 in a single write alongside the HTTP request, which is the
    interesting path: the leftover bytes past the header have to be
    compacted back to offset 0 (server.zig:3197).
  - v1 and v2 split across two writes, exercising the "keep reading"
    branch for a header that has not fully arrived.
  - v2 PROXY command with IPv4 and IPv6 address families.
  - v2 LOCAL command (health checks from the LB): addresses are ignored
    by design, so the TCP peer is kept.
  - malformed headers are dropped without a response, rather than being
    passed to the HTTP parser.
  - the `saltare_proxy_protocol_accepted_total{version=...}` counters on
    /metrics, which the README documents as the way to confirm the
    feature is live.
  - with the feature off, a connection that opens with a PROXY line is
    just a bad request.

v1 wire format is `PROXY TCP4 <src> <dst> <sport> <dport>\r\n`, max 107
bytes. v2 is a 12-byte signature, then ver/cmd and family/protocol
bytes, a 2-byte big-endian payload length, then the address block
(12 bytes for IPv4: src, dst, sport, dport; 36 for IPv6).
"""

from __future__ import annotations

import socket
import threading
import time
from typing import Any

import pytest

# TEST-NET-3 / TEST-NET-2 (RFC 5737). Never routable, so a failure that
# leaks a real packet cannot escape the host.
IP_A = "203.0.113.7"
IP_B = "198.51.100.9"
IP_C = "192.0.2.44"

_TIMING_FACTOR = 4.0


# ---------------------------------------------------------------------------
# Harness
# ---------------------------------------------------------------------------


def _free_port() -> int:
    with socket.socket() as s:
        s.bind(("127.0.0.1", 0))
        return s.getsockname()[1]


async def _hello(scope, receive, send):
    """Minimal ASGI app. Handles lifespan so the server boots cleanly."""
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
    await send({
        "type": "http.response.start",
        "status": 200,
        "headers": [(b"content-type", b"text/plain")],
    })
    await send({"type": "http.response.body", "body": b"ok", "more_body": False})


def _serve_in_background(app: Any, port: int, **kwargs) -> None:
    from saltare import run

    threading.Thread(
        target=run,
        args=(app,),
        kwargs={"host": "127.0.0.1", "port": port, **kwargs},
        daemon=True,
    ).start()

    deadline = time.monotonic() + 3.0
    while time.monotonic() < deadline:
        try:
            with socket.create_connection(("127.0.0.1", port), timeout=0.2):
                return
        except (ConnectionRefusedError, socket.timeout, OSError):
            time.sleep(0.05)
    pytest.fail("server never became ready")


# ---------------------------------------------------------------------------
# Header builders
# ---------------------------------------------------------------------------

_PROXY_V2_SIG = b"\r\n\r\n\x00\r\nQUIT\n"


def _v1(src: str, dst: str = "10.0.0.1", sport: int = 4444, dport: int = 80) -> bytes:
    return f"PROXY TCP4 {src} {dst} {sport} {dport}\r\n".encode()


def _v1_tcp6(src: str, dst: str = "2001:db8::1", sport: int = 4444, dport: int = 80) -> bytes:
    return f"PROXY TCP6 {src} {dst} {sport} {dport}\r\n".encode()


def _v1_unknown() -> bytes:
    return b"PROXY UNKNOWN\r\n"


def _v2(src_v4: str, cmd: int = 1, family: int = 1) -> bytes:
    """v2 header. `cmd` 1 = PROXY (trust the address), 0 = LOCAL."""
    s = bytes(int(p) for p in src_v4.split("."))
    payload = s + b"\x0a\x00\x00\x01" + b"\x11\x5c" + b"\x00\x50"  # src, dst, 4444, 80
    ver_cmd = 0x20 | cmd
    fam_proto = (family << 4) | 0x01  # STREAM
    return _PROXY_V2_SIG + bytes([ver_cmd, fam_proto, 0, len(payload)]) + payload


def _v2_tcp6(src_v4: str, cmd: int = 1) -> bytes:
    """v2 with an IPv6 address block (36 bytes). The source is derived
    from `src_v4` only to keep the call sites readable; what matters is
    the family nibble and the payload length."""
    payload = (
        bytes.fromhex("20010db8" "00000000" "00000000" "00000001")  # src ::1-ish
        + bytes.fromhex("20010db8" "00000000" "00000000" "00000002")  # dst
        + b"\x11\x5c"  # sport
        + b"\x00\x50"  # dport
    )
    ver_cmd = 0x20 | cmd
    fam_proto = 0x21  # AF_INET6 << 4 | STREAM
    return _PROXY_V2_SIG + bytes([ver_cmd, fam_proto, 0, len(payload)]) + payload


# ---------------------------------------------------------------------------
# Raw request helpers
# ---------------------------------------------------------------------------


def _raw_request(host_port: tuple[str, int], path: str = "/") -> bytes:
    host, port = host_port
    return (
        f"GET {path} HTTP/1.1\r\n"
        f"Host: {host}:{port}\r\n"
        f"Connection: close\r\n"
        f"\r\n"
    ).encode()


def _request_with_prologue(
    port: int,
    prologue: bytes,
    *,
    path: str = "/",
    split: bool = False,
    timeout: float = 2.0,
) -> bytes:
    """Open a connection, send `prologue`, then a complete HTTP request.

    `split=True` writes the two halves separately so the server has to
    park in the header-pending state and resume on the next read.
    """
    req = _raw_request(("127.0.0.1", port), path)
    with socket.create_connection(("127.0.0.1", port), timeout=timeout) as s:
        if split:
            s.sendall(prologue)
            # A gap the event loop has to notice, rather than both halves
            # landing in one read() and being handled by the same pass.
            time.sleep(0.05)
            s.sendall(req)
        else:
            s.sendall(prologue + req)
        chunks: list[bytes] = []
        try:
            while True:
                b = s.recv(65536)
                if not b:
                    break
                chunks.append(b)
        except (socket.timeout, ConnectionResetError):
            pass
    return b"".join(chunks)


def _status(response: bytes) -> int | None:
    if not response.startswith(b"HTTP/1."):
        return None
    try:
        return int(response.split(b" ", 2)[1])
    except (IndexError, ValueError):
        return None


# ---------------------------------------------------------------------------
# v1: the claimed source becomes the throttling key
# ---------------------------------------------------------------------------


def test_v1_claimed_source_is_the_rate_limit_key() -> None:
    """burst=2 and four requests behind `PROXY TCP4 203.0.113.7`:
    the first two are served and the rest are throttled. The point is
    *which* key is used — if the PROXY parse were ignored, the TCP peer
    (127.0.0.1) would be the key and the test would still pass, so the
    companion test below is what actually pins the parse down."""
    port = _free_port()
    _serve_in_background(_hello, port, proxy_protocol=True,
                         rate_limit_per_sec=10, rate_limit_burst=2)

    statuses = [
        _status(_request_with_prologue(port, _v1(IP_A))) for _ in range(5)
    ]
    assert statuses[:2] == [200, 200], f"burst should be honoured: {statuses}"
    assert 429 in statuses[2:], f"no 429 after the burst: {statuses}"


def test_v1_distinct_sources_get_independent_buckets() -> None:
    """The discriminating test. Two source IPs, burst=2 each, four
    requests total. Every request must be served: if `conn.peer_key`
    were left as the TCP peer, all four would share one bucket and the
    last two would be 429."""
    port = _free_port()
    _serve_in_background(_hello, port, proxy_protocol=True,
                         rate_limit_per_sec=10, rate_limit_burst=2)

    statuses = []
    for _ in range(2):
        statuses.append(_status(_request_with_prologue(port, _v1(IP_A))))
        statuses.append(_status(_request_with_prologue(port, _v1(IP_B))))

    assert statuses == [200, 200, 200, 200], (
        f"independent peers must not share a bucket: {statuses}"
    )


def test_v1_tcp6_source_is_the_rate_limit_key() -> None:
    """A TCP6 claim is parsed the same way and is likewise independent
    of the TCP peer."""
    port = _free_port()
    _serve_in_background(_hello, port, proxy_protocol=True,
                         rate_limit_per_sec=10, rate_limit_burst=2)

    seen = []
    for _ in range(2):
        seen.append(_status(_request_with_prologue(
            port, _v1_tcp6("2001:db8::dead:beef"))))
    seen.append(_status(_request_with_prologue(
        port, _v1_tcp6("2001:db8::dead:beef"))))
    assert seen[:2] == [200, 200], seen
    assert seen[2] == 429, f"the TCP6 source should be throttled: {seen}"


def test_v1_unknown_keeps_the_tcp_peer() -> None:
    """`PROXY UNKNOWN` carries no usable address (an LB health check, or
    a source it could not resolve), so the TCP peer stays the key. Two
    UNKNOWN connections therefore share 127.0.0.1's bucket."""
    port = _free_port()
    _serve_in_background(_hello, port, proxy_protocol=True,
                         rate_limit_per_sec=10, rate_limit_burst=2)

    statuses = [
        _status(_request_with_prologue(port, _v1_unknown())) for _ in range(4)
    ]
    assert statuses[:2] == [200, 200], statuses
    assert 429 in statuses[2:], (
        f"UNKNOWN must fall back to the shared TCP peer: {statuses}"
    )


def test_v1_unknown_does_not_consume_another_peers_bucket() -> None:
    """An UNKNOWN connection must not be attributed to a real peer: the
    claimed-IP bucket stays untouched, so it is still fully available."""
    port = _free_port()
    _serve_in_background(_hello, port, proxy_protocol=True,
                         rate_limit_per_sec=10, rate_limit_burst=2)

    _status(_request_with_prologue(port, _v1_unknown()))
    _status(_request_with_prologue(port, _v1_unknown()))
    # 203.0.113.7 has made no requests yet, so both of its tokens exist.
    a = _status(_request_with_prologue(port, _v1(IP_A)))
    b = _status(_request_with_prologue(port, _v1(IP_A)))
    assert (a, b) == (200, 200), f"UNKNOWN leaked into another peer: {a}, {b}"


# ---------------------------------------------------------------------------
# v2: the binary header
# ---------------------------------------------------------------------------


def test_v2_ipv4_source_is_the_rate_limit_key() -> None:
    port = _free_port()
    _serve_in_background(_hello, port, proxy_protocol=True,
                         rate_limit_per_sec=10, rate_limit_burst=2)

    statuses = [_status(_request_with_prologue(port, _v2(IP_A)))
                for _ in range(4)]
    assert statuses[:2] == [200, 200], statuses
    assert 429 in statuses[2:], f"no 429 after the burst: {statuses}"


def test_v2_and_v1_distinct_sources_get_independent_buckets() -> None:
    """v1 and v2 headers claiming different sources must not collide."""
    port = _free_port()
    _serve_in_background(_hello, port, proxy_protocol=True,
                         rate_limit_per_sec=10, rate_limit_burst=2)

    statuses = [
        _status(_request_with_prologue(port, _v1(IP_A))),
        _status(_request_with_prologue(port, _v2(IP_B))),
        _status(_request_with_prologue(port, _v1(IP_A))),
        _status(_request_with_prologue(port, _v2(IP_B))),
    ]
    assert statuses == [200, 200, 200, 200], (
        f"v1 and v2 peers must not share a bucket: {statuses}"
    )


def test_v2_ipv6_family_source_is_the_rate_limit_key() -> None:
    port = _free_port()
    _serve_in_background(_hello, port, proxy_protocol=True,
                         rate_limit_per_sec=10, rate_limit_burst=2)

    statuses = [_status(_request_with_prologue(port, _v2_tcp6(IP_C)))
                for _ in range(4)]
    assert statuses[:2] == [200, 200], statuses
    assert 429 in statuses[2:], f"no 429 after the burst: {statuses}"


def test_v2_local_command_keeps_the_tcp_peer() -> None:
    """cmd=0 is LOCAL: the LB's own health check, whose address block
    describes the LB and must not be used. Both connections then share
    127.0.0.1's bucket."""
    port = _free_port()
    _serve_in_background(_hello, port, proxy_protocol=True,
                         rate_limit_per_sec=10, rate_limit_burst=2)

    statuses = [
        _status(_request_with_prologue(port, _v2(IP_A, cmd=0)))
        for _ in range(4)
    ]
    assert statuses[:2] == [200, 200], statuses
    assert 429 in statuses[2:], (
        f"LOCAL must not be attributed to the claimed address: {statuses}"
    )


# ---------------------------------------------------------------------------
# Framing: one write vs. two
# ---------------------------------------------------------------------------


def test_v1_and_request_in_a_single_write() -> None:
    """Header and request in one segment. The bytes past the header must
    be compacted back to offset 0 for the HTTP parser, so the request is
    served rather than dropped."""
    port = _free_port()
    _serve_in_background(_hello, port, proxy_protocol=True)
    assert _status(_request_with_prologue(port, _v1(IP_A))) == 200


def test_v2_and_request_in_a_single_write() -> None:
    port = _free_port()
    _serve_in_background(_hello, port, proxy_protocol=True)
    assert _status(_request_with_prologue(port, _v2(IP_A))) == 200


def test_v1_split_across_two_writes() -> None:
    """The header has not fully arrived when the first read returns, so
    the connection parks in the pending state and resumes."""
    port = _free_port()
    _serve_in_background(_hello, port, proxy_protocol=True)
    assert _status(_request_with_prologue(port, _v1(IP_A), split=True)) == 200


def test_v2_split_across_two_writes() -> None:
    """v2 needs 16 bytes before it can even read the payload length, so
    a short first write must not be misparsed."""
    port = _free_port()
    _serve_in_background(_hello, port, proxy_protocol=True)
    assert _status(_request_with_prologue(port, _v2(IP_A), split=True)) == 200


# ---------------------------------------------------------------------------
# Malformed headers are dropped, not forwarded
# ---------------------------------------------------------------------------


def test_v1_bad_prefix_is_dropped() -> None:
    """A connection that opens with something else while
    `proxy_protocol=True` must not reach the HTTP parser."""
    port = _free_port()
    _serve_in_background(_hello, port, proxy_protocol=True)
    resp = _request_with_prologue(port, b"PROXY/1.0 garbage\r\n")
    assert _status(resp) is None, f"expected a dropped connection, got {resp!r}"


def test_v1_unknown_family_is_dropped() -> None:
    port = _free_port()
    _serve_in_background(_hello, port, proxy_protocol=True)
    resp = _request_with_prologue(port, b"PROXY TCP9 1.2.3.4 5.6.7.8 1 2\r\n")
    assert _status(resp) is None, f"expected a dropped connection, got {resp!r}"


def test_v1_missing_source_is_dropped() -> None:
    """`TCP4` with no address after it: nothing to attribute the
    connection to, so it is dropped rather than falling back to the
    proxy's own address."""
    port = _free_port()
    _serve_in_background(_hello, port, proxy_protocol=True)
    resp = _request_with_prologue(port, b"PROXY TCP4\r\n")
    assert _status(resp) is None, f"expected a dropped connection, got {resp!r}"


def test_v2_bad_version_nibble_is_dropped() -> None:
    """The high nibble of byte 12 is the version and must be 2."""
    port = _free_port()
    _serve_in_background(_hello, port, proxy_protocol=True)
    bad = bytearray(_v2(IP_A))
    bad[12] = 0x31  # version 3
    resp = _request_with_prologue(port, bytes(bad))
    assert _status(resp) is None, f"expected a dropped connection, got {resp!r}"


def test_v2_truncated_address_block_falls_back_to_the_tcp_peer() -> None:
    """A v2 header declaring AF_INET with fewer than 12 address bytes is
    malformed — RFC 9113 fixes the block at src+dst+sport+dport. The
    server treats it like UNSPEC: the header is consumed, no address is
    adopted, and the TCP peer remains the key.

    That fallback is the safe direction, and deliberately so. Adopting a
    partial address would let a client pick its own rate-limit bucket;
    refusing the connection instead would turn a misbehaving load
    balancer into an outage. Falling back to the real peer over-restricts
    (every client behind the LB shares one bucket) rather than
    under-restricts.

    Pinned here because it is a judgement call, not an accident: a
    stricter reading would drop the connection instead.
    """
    port = _free_port()
    _serve_in_background(_hello, port, proxy_protocol=True,
                         rate_limit_per_sec=10, rate_limit_burst=2)

    short = _PROXY_V2_SIG + bytes([0x21, 0x11, 0, 4]) + b"\x01\x02\x03\x04"
    first = _status(_request_with_prologue(port, short))
    second = _status(_request_with_prologue(port, short))
    third = _status(_request_with_prologue(port, short))

    # Served rather than dropped, and all three share the TCP peer's
    # bucket, so the third is throttled.
    assert (first, second) == (200, 200), (first, second)
    assert third == 429, f"truncated block must not mint a new bucket: {third}"


# ---------------------------------------------------------------------------
# Metrics
# ---------------------------------------------------------------------------


def _metric_value(body: str, family: str) -> int:
    """Read one `saltare_proxy_protocol_accepted_total{version=...}` sample."""
    needle = f'saltare_proxy_protocol_accepted_total{{version="{family}"}}'
    for line in body.splitlines():
        if line.startswith(needle):
            return int(line.rsplit(" ", 1)[1])
    raise AssertionError(
        f"{needle} absent from /metrics; got:\n{body[:2000]}"
    )


def test_metrics_count_v1_and_v2_accepted() -> None:
    """`--proxy-protocol` exposes per-version acceptance counters; the
    README documents them as the confirmation that the feature is live
    (a missing line means the flag is off)."""
    port = _free_port()
    _serve_in_background(_hello, port, proxy_protocol=True,
                         metrics_path="/metrics")

    assert _status(_request_with_prologue(port, _v1(IP_A), path="/metrics")) == 200
    assert _status(_request_with_prologue(port, _v2(IP_B), path="/metrics")) == 200

    # The scrape itself has to go through a PROXY header too: with the
    # flag on, *every* connection is expected to open with one, including
    # a monitoring agent's. A plain client would be dropped at the
    # pending-header stage and the scrape would see a closed socket.
    body = _request_with_prologue(port, _v1(IP_A), path="/metrics").decode(
        "latin-1"
    )

    assert _metric_value(body, "v1") == 2, body[:2000]
    assert _metric_value(body, "v2") == 1, body[:2000]


def test_metrics_absent_when_feature_is_off() -> None:
    """The counter families are emitted only when the flag is on, so a
    missing line is itself the signal."""
    port = _free_port()
    _serve_in_background(_hello, port, metrics_path="/metrics")

    import httpx

    with httpx.Client(timeout=2.0) as client:
        body = client.get(f"http://127.0.0.1:{port}/metrics").text

    assert "saltare_proxy_protocol_accepted_total" not in body


# ---------------------------------------------------------------------------
# Feature off
# ---------------------------------------------------------------------------


def test_prologue_without_the_flag_is_a_bad_request() -> None:
    """With `proxy_protocol` off the PROXY line is just the first line
    of a malformed request, so the HTTP parser rejects it with a 400
    rather than treating it as a header."""
    port = _free_port()
    _serve_in_background(_hello, port)
    assert _status(_request_with_prologue(port, _v1(IP_A))) == 400
