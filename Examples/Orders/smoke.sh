#!/usr/bin/env bash
# Smoke test for the orders example: a valid start serves /healthz and /config without the secret,
# and a bad environment stops startup with every problem listed.
# Usage: ./smoke.sh [path/to/Orders]   (default: builds it with swift build)
set -euo pipefail
cd "$(dirname "$0")"

bin=${1:-}
if [ -z "$bin" ]; then
    swift build
    bin="$(swift build --show-bin-path)/Orders"
fi
port=${SMOKE_PORT:-$((20000 + RANDOM % 20000))}
secret='postgres://orders:s3cr3t-pa55@db.internal:5432/orders'

# GET over bash's /dev/tcp, so the script needs no curl.
get() {
    exec 3<>"/dev/tcp/127.0.0.1/$port" || return 1
    printf 'GET %s HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n' "$1" >&3
    local response
    response=$(cat <&3)
    exec 3<&-
    printf '%s' "${response#*$'\r\n\r\n'}"
}

fail() { echo "FAIL: $*" >&2; exit 1; }

# 1. Valid environment.
get /healthz >/dev/null 2>&1 && fail "port $port is already in use; set SMOKE_PORT"
PORT=$port DATABASE_URL=$secret "$bin" &
pid=$!
trap 'kill $pid 2>/dev/null || true' EXIT
for _ in $(seq 50); do
    get /healthz >/dev/null 2>&1 && break
    kill -0 $pid 2>/dev/null || fail "the app exited during startup"
    sleep 0.2
done
kill -0 $pid 2>/dev/null || fail "the app is not running (is port $port taken?)"
health=$(get /healthz) || fail "no answer on port $port"
[ "$health" = ok ] || fail "/healthz returned '$health'"
config=$(get /config)
echo "$config"
case "$config" in *s3cr3t*|*db.internal*) fail "/config leaks the secret" ;; esac
case "$config" in *'"***"'*) ;; *) fail "/config does not show the redacted secret" ;; esac
kill -0 $pid 2>/dev/null || fail "the app stopped while serving"
kill $pid
wait $pid 2>/dev/null || true
trap - EXIT
echo "ok: valid start"

# 2. PORT=0 and no DATABASE_URL: startup fails with both problems.
status=0
output=$(env -u DATABASE_URL PORT=0 "$bin" 2>&1) || status=$?
echo "$output"
[ "$status" -ne 0 ] || fail "the app started with an invalid environment"
grep -q missing_required <<<"$output" || fail "no missing_required in the output"
grep -q out_of_range <<<"$output" || fail "no out_of_range in the output"
echo "ok: invalid start exits $status"
