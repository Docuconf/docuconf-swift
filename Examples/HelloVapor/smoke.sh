#!/usr/bin/env bash
# Smoke test for the Vapor recipe. DATABASE_URL and GREETING come only from a .env file, which Vapor loads in
# Application.make: the app booting proves docuconf reads the environment after Vapor has loaded it.
# Usage: ./smoke.sh [path/to/App]   (default: builds it with swift build)
set -euo pipefail
cd "$(dirname "$0")"
bin=${1:-}
if [ -z "$bin" ]; then
    swift build
    bin="$(swift build --show-bin-path)/App"
fi
port=${SMOKE_PORT:-$((20000 + RANDOM % 20000))}
work=$(mktemp -d)
fail() { echo "FAIL: $*" >&2; exit 1; }
get() {
    exec 3<>"/dev/tcp/127.0.0.1/$port" || return 1
    printf 'GET %s HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n' "$1" >&3
    local response
    response=$(cat <&3)
    exec 3<&-
    printf '%s' "${response#*$'\r\n\r\n'}"
}

printf 'DATABASE_URL=postgres://localhost/hello\nGREETING=hello from .env\nPORT=%s\n' "$port" > "$work/.env"
(cd "$work" && exec env -u DATABASE_URL -u GREETING -u PORT DOCUCONF_TERMINATION_LOG= "$bin" serve --hostname 127.0.0.1) &
pid=$!
trap 'kill $pid 2>/dev/null || true; rm -rf "$work"' EXIT
for _ in $(seq 100); do get /healthz >/dev/null 2>&1 && break; kill -0 $pid 2>/dev/null || fail "exited during startup"; sleep 0.2; done
[ "$(get /)" = "hello from .env" ] || fail "/ did not serve the greeting from .env"
echo "ok: boots on values from .env"
kill $pid; wait $pid 2>/dev/null || true

rm "$work/.env"
status=0
out=$(cd "$work" && env -u DATABASE_URL DOCUCONF_TERMINATION_LOG= "$bin" serve 2>&1) || status=$?
[ "$status" -eq 1 ] || fail "expected exit 1 without DATABASE_URL, got $status"
grep -q 'DATABASE_URL \[missing_required\]' <<<"$out" || fail "no missing_required: $out"
echo "ok: refuses to start without DATABASE_URL"
