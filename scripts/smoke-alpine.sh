#!/usr/bin/env bash
# Verify the musllinux wheel actually loads + serves on a real Alpine
# container. Cibuildwheel builds + tests run under manylinux runtime; this
# script catches regressions where the wheel compiles but trips on
# Alpine-specific dynamic-linker / libc-isms (`/lib/ld-musl-x86_64.so.1`,
# `dlopen` resolving differently for libssl/libz, etc.).
#
# Run AFTER a wheel build:
#   ls dist/saltare-*-musllinux*.whl
#   bash scripts/smoke-alpine.sh dist/saltare-1.5.0-cp314-cp314-musllinux_1_2_x86_64.whl
#
# The smoke spins up a tiny ASGI app, hits /, /metrics, /debug/dispatch
# and verifies non-error status codes. Exit non-zero on any failure.

set -euo pipefail

if [[ $# -ne 1 ]]; then
    echo "usage: $0 <wheel-path>" >&2
    exit 64
fi

WHEEL="$(realpath "$1")"
if [[ ! -f "$WHEEL" ]]; then
    echo "wheel not found: $WHEEL" >&2
    exit 1
fi

case "$WHEEL" in
    *musllinux*) ;;
    *) echo "warning: $WHEEL is not a musllinux wheel; smoke will run but proves nothing about Alpine" >&2 ;;
esac

WHEEL_NAME="$(basename "$WHEEL")"
WHEEL_DIR="$(dirname "$WHEEL")"

# Pick the Python tag the wheel was built for so pip won't reject it.
PYTAG="$(echo "$WHEEL_NAME" | sed -nE 's/.*-(cp[0-9]+)-.*/\1/p')"
PYVER="${PYTAG#cp}"
PYVER="${PYVER:0:1}.${PYVER:1}"

echo "=== Alpine smoke: $WHEEL_NAME (python $PYVER) ==="

docker run --rm --platform=linux/amd64 \
    -v "$WHEEL_DIR:/wheels:ro" \
    "alpine:3.20" sh -c "
set -e
apk add --no-cache python3 py3-pip curl >/dev/null 2>&1 || true
# Some Alpine images lock /usr/lib/python3.X — use --break-system-packages
# (or a venv). Venv is cleanest.
python3 -m venv /opt/v
. /opt/v/bin/activate
pip install --quiet '/wheels/$WHEEL_NAME' httpx
mkdir -p /app
cat > /app/app.py <<'EOF'
async def app(scope, receive, send):
    if scope['type'] == 'lifespan':
        while True:
            m = await receive()
            if m['type'] == 'lifespan.startup': await send({'type':'lifespan.startup.complete'})
            elif m['type'] == 'lifespan.shutdown': await send({'type':'lifespan.shutdown.complete'}); return
        return
    await receive()
    await send({'type':'http.response.start','status':200,'headers':[(b'content-type',b'text/plain')]})
    await send({'type':'http.response.body','body':b'ok\n','more_body':False})
EOF
cd /app
saltare app:app --host 127.0.0.1 --port 8765 \
    --metrics-path /metrics --dispatch-path /debug/dispatch \
    --shutdown-timeout 1 > /tmp/srv.log 2>&1 &
SALTARE_PID=\$!

# Wait for listen.
for i in 1 2 3 4 5 6 7 8 9 10; do
    if curl -s -o /dev/null http://127.0.0.1:8765/; then break; fi
    sleep 0.5
done

ok=0
for path in '/' '/metrics' '/debug/dispatch'; do
    code=\$(curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:8765\$path)
    echo \"\$path -> \$code\"
    case \$code in 2*) ;; *) ok=1 ;; esac
done

kill \$SALTARE_PID 2>/dev/null || true
wait 2>/dev/null || true

if [ \$ok -ne 0 ]; then
    echo '--- saltare stderr ---'
    cat /tmp/srv.log
    exit 1
fi
echo 'alpine smoke: OK'
"
