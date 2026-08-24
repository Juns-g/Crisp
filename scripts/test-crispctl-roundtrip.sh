#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCRATCH="${1:-/tmp/crispctl-roundtrip-build}"
SOCKET_DIR="$(mktemp -d /tmp/crispctl-roundtrip.XXXXXX)"
SOCKET="$SOCKET_DIR/control.sock"
HOST="$SCRATCH/out/Products/Debug/crisp-control-test-host"
CLI="$SCRATCH/out/Products/Debug/crispctl"
HOST_PID=""

cleanup() {
    if [ -n "$HOST_PID" ]; then
        kill "$HOST_PID" 2>/dev/null || true
        wait "$HOST_PID" 2>/dev/null || true
    fi
    rm -f "$SOCKET"
    rmdir "$SOCKET_DIR"
}
trap cleanup EXIT

cd "$ROOT"
SWIFTPM_MODULECACHE_OVERRIDE=/tmp/crisp-spm-module-cache \
CLANG_MODULE_CACHE_PATH=/tmp/crisp-clang-module-cache \
swift build --disable-sandbox --scratch-path "$SCRATCH"

"$HOST" "$SOCKET" &
HOST_PID=$!
for _ in {1..100}; do
    [ -S "$SOCKET" ] && break
    kill -0 "$HOST_PID" 2>/dev/null || { wait "$HOST_PID"; exit 1; }
    sleep 0.01
done
[ -S "$SOCKET" ]

STATUS="$("$CLI" status --json --no-start --socket "$SOCKET")"
LIST="$("$CLI" displays list --json --no-start --socket "$SOCKET")"
SET="$("$CLI" brightness set builtin 55 --json --no-start --socket "$SOCKET")"
GET="$("$CLI" brightness get fixture-built-in --json --no-start --socket "$SOCKET")"

jq -e '.ok and .result.running' <<<"$STATUS" >/dev/null
jq -e '.ok and .result.displays[0].uuid == "fixture-built-in"' <<<"$LIST" >/dev/null
jq -e '.ok and .result.verification == "verified" and .result.readbackPercent == 55' <<<"$SET" >/dev/null
jq -e '.ok and .result.percent == 55' <<<"$GET" >/dev/null
[ "$(stat -f '%Lp' "$SOCKET")" = "600" ]

kill "$HOST_PID"
wait "$HOST_PID"
HOST_PID=""

echo "CRISPCTL_HEADLESS_ROUNDTRIP_OK"
