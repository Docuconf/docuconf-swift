#!/usr/bin/env bash
# Smoke test for the Hummingbird recipe: the app boots with the validated port, serves the watched greeting, picks up
# a change to the greeting file while running, and refuses to start without DATABASE_URL.
# Usage: ./smoke.sh [path/to/App]   (default: builds it with swift build)
set -euo pipefail
cd "$(dirname "$0")"
bin=${1:-}
if [ -z "$bin" ]; then
    swift build
    bin="$(swift build --show-bin-path)/App"
fi
port=${SMOKE_PORT:-$((20000 + RANDOM % 20000))}
root=$(mktemp -d)
fail() { echo "FAIL: $*" >&2; exit 1; }
get() {
    exec 3<>"/dev/tcp/127.0.0.1/$port" || return 1
    printf 'GET %s HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n' "$1" >&3
    local response
    response=$(cat <&3)
    exec 3<&-
    printf '%s' "${response#*$'\r\n\r\n'}"
}

mkdir -p "$root/etc/hello"
echo '{"text":"hello"}' > "$root/etc/hello/greeting.json"
HTTP_HOST=127.0.0.1 HTTP_PORT=$port DATABASE_URL=postgres://localhost/hello DOCUCONF_FILE_ROOT=$root DOCUCONF_TERMINATION_LOG= "$bin" &
pid=$!
trap 'kill $pid 2>/dev/null || true; rm -rf "$root"' EXIT
for _ in $(seq 100); do get /healthz >/dev/null 2>&1 && break; kill -0 $pid 2>/dev/null || fail "exited during startup"; sleep 0.2; done
[ "$(get /)" = hello ] || fail "/ did not serve the greeting"
echo '{"text":"hi again"}' > "$root/etc/hello/greeting.json"
for _ in $(seq 60); do [ "$(get /)" = "hi again" ] && break; sleep 0.25; done
[ "$(get /)" = "hi again" ] || fail "the changed greeting was not picked up"
echo "ok: serves and reloads the greeting"
kill $pid; wait $pid 2>/dev/null || true

status=0
out=$(env -u DATABASE_URL DOCUCONF_FILE_ROOT=$root DOCUCONF_TERMINATION_LOG= "$bin" 2>&1) || status=$?
[ "$status" -eq 1 ] || fail "expected exit 1 without DATABASE_URL, got $status"
grep -q 'DATABASE_URL \[missing_required\]' <<<"$out" || fail "no missing_required: $out"
echo "ok: refuses to start without DATABASE_URL"
