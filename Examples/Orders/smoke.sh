#!/usr/bin/env bash
# Smoke test for the orders example: a valid start serves /healthz and /config without the secret,
# a bad environment stops startup with every problem listed, and webhooks signed with either key of a key set
# that is mid-rotation are accepted. Needs openssl for the signatures.
# Usage: ./smoke.sh [path/to/Orders]   (default: builds it with swift build)
set -euo pipefail
cd "$(dirname "$0")"

bin=${1:-}
if [ -z "$bin" ]; then
    swift build
    bin="$(swift build --show-bin-path)/Orders"
fi
log=$(mktemp)
port=${SMOKE_PORT:-$((20000 + RANDOM % 20000))}
secret='postgres://orders:s3cr3t-pa55@db.internal:5432/orders'
# Two webhook keys: the old one and, mid-rotation, the new one.
old_key='old-webhook-key-0123456789abcdef0123'
new_key='new-webhook-key-0123456789abcdef0123'

# GET over bash's /dev/tcp, so the script needs no curl.
get() {
    exec 3<>"/dev/tcp/127.0.0.1/$port" || return 1
    printf 'GET %s HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n' "$1" >&3
    local response
    response=$(cat <&3)
    exec 3<&-
    printf '%s' "${response#*$'\r\n\r\n'}"
}

# POST a body with an X-Signature header; prints the status code.
post() { # path signature body
    exec 3<>"/dev/tcp/127.0.0.1/$port" || return 1
    printf 'POST %s HTTP/1.1\r\nHost: localhost\r\nX-Signature: %s\r\nContent-Length: %s\r\nConnection: close\r\n\r\n%s' \
        "$1" "$2" "${#3}" "$3" >&3
    local response
    response=$(cat <&3)
    exec 3<&-
    local status=${response#HTTP/1.1 }
    printf '%s' "${status%% *}"
}

fail() { echo "FAIL: $*" >&2; exit 1; }

# 1. Valid environment.
get /healthz >/dev/null 2>&1 && fail "port $port is already in use; set SMOKE_PORT"
PORT=$port DATABASE_URL=$secret WEBHOOK_KEYS="$old_key,$new_key" "$bin" >"$log" 2>&1 &
pid=$!
trap 'kill $pid 2>/dev/null || true; rm -f "$log"' EXIT
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
case "$config" in *s3cr3t*|*db.internal*|*webhook-key*) fail "/config leaks a secret" ;; esac
case "$config" in *'"databaseURL" : "***"'*) ;; *) fail "/config does not show the redacted DATABASE_URL" ;; esac
case "$config" in *'"webhookKeys" : "***"'*) ;; *) fail "/config does not show the redacted WEBHOOK_KEYS" ;; esac
grep -q -e s3cr3t -e webhook-key "$log" && fail "the log leaks a secret"

# Mid-rotation, a webhook signed with either key is accepted, and one signed with any other key, or unsigned, is not.
[ "$(post /webhooks/payments 00 '{}')" = 401 ] || fail "an unsigned webhook was not rejected with 401"
body='{"order":"42","status":"paid"}'
for key in "$old_key" "$new_key" "other-webhook-key-0123456789abcdef"; do
    sig=$(printf '%s' "$body" | openssl dgst -sha256 -hmac "$key" | sed 's/.*= //')
    want=204; [ "${key#other}" != "$key" ] && want=401
    code=$(post /webhooks/payments "$sig" "$body")
    [ "$code" = "$want" ] || fail "webhook signed with the ${key%%-*} key: got $code, want $want"
done
echo "ok: webhooks signed with the old and the new key accepted, any other rejected"
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

# 3. An empty second webhook key (a trailing comma): the key set fails it at boot, without printing a key.
status=0
output=$(DATABASE_URL=$secret WEBHOOK_KEYS="$old_key," "$bin" 2>&1) || status=$?
echo "$output"
[ "$status" -eq 1 ] || fail "want exit 1 for an empty webhook key, got $status"
grep -q 'WEBHOOK_KEYS \[out_of_range\]: key 1 is empty' <<<"$output" || fail "no WEBHOOK_KEYS out_of_range for the empty key in the output"
grep -q webhook-key <<<"$output" && fail "the output leaks a webhook key"
echo "ok: an empty webhook key exits 1"
