#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCRATCH="${1:-/tmp/crispctl-roundtrip-build}"
SOCKET_DIR="$(mktemp -d /tmp/crispctl-roundtrip.XXXXXX)"
SOCKET="$SOCKET_DIR/control.sock"
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
BUILD_ARGS=(swift build --disable-sandbox --scratch-path "$SCRATCH")
SWIFTPM_MODULECACHE_OVERRIDE=/tmp/crisp-spm-module-cache \
CLANG_MODULE_CACHE_PATH=/tmp/crisp-clang-module-cache \
"${BUILD_ARGS[@]}"
BIN_PATH="$(
    SWIFTPM_MODULECACHE_OVERRIDE=/tmp/crisp-spm-module-cache \
    CLANG_MODULE_CACHE_PATH=/tmp/crisp-clang-module-cache \
    "${BUILD_ARGS[@]}" --show-bin-path
)"
HOST="$BIN_PATH/crisp-control-test-host"
CLI="$BIN_PATH/crispctl"

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
EXTRA_GET="$("$CLI" extra-brightness get fixture-built-in --json --no-start --socket "$SOCKET")"
EXTRA_SET="$("$CLI" extra-brightness set fixture-built-in on --json --no-start --socket "$SOCKET")"
BOOSTED_SET="$("$CLI" brightness set fixture-built-in 125 --json --no-start --socket "$SOCKET")"
HDR_GET="$("$CLI" hdr get fixture-external --json --no-start --socket "$SOCKET")"
HDR_SET="$("$CLI" hdr set fixture-external off --json --no-start --socket "$SOCKET")"
GET_ALL="$("$CLI" brightness get-all --json --no-start --socket "$SOCKET")"
SET_ALL="$("$CLI" brightness set-all 60 --json --no-start --socket "$SOCKET")"

jq -e '.ok and .result.running' <<<"$STATUS" >/dev/null
jq -e '.ok and .result.displays[0].uuid == "fixture-built-in"' <<<"$LIST" >/dev/null
jq -e '.ok and .result.verification == "verified" and .result.readbackPercent == 55' <<<"$SET" >/dev/null
jq -e '.ok and .result.percent == 55' <<<"$GET" >/dev/null
jq -e '.ok and (.result.enabled | not) and .result.maxBrightness == 100' <<<"$EXTRA_GET" >/dev/null
jq -e '.ok and .result.enabled and .result.verification == "app_state_verified" and .result.maxBrightness == 150' <<<"$EXTRA_SET" >/dev/null
jq -e '.ok and .result.logicalPercent == 125 and .result.hardwareReadbackPercent == 100 and .result.verification == "app_state_verified"' <<<"$BOOSTED_SET" >/dev/null
jq -e '.ok and .result.enabled' <<<"$HDR_GET" >/dev/null
jq -e '.ok and (.result.enabled | not) and .result.verification == "verified"' <<<"$HDR_SET" >/dev/null
jq -e '.ok and .result.displays[0].displayUUID == "fixture-built-in" and .result.displays[1].displayUUID == "fixture-external"' <<<"$GET_ALL" >/dev/null
jq -e '.ok and .result.appliedUUIDs == ["fixture-built-in", "fixture-external"] and (.result.outcomes | length) == 2' <<<"$SET_ALL" >/dev/null
[ "$(stat -f '%Lp' "$SOCKET")" = "600" ]

kill "$HOST_PID"
wait "$HOST_PID"
HOST_PID=""

echo "CRISPCTL_HEADLESS_ROUNDTRIP_OK"
