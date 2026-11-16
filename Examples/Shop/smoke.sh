#!/usr/bin/env bash
# Smoke test for the shop example: runs the real app process for cases 1, 2 and 6 of the README's matrix, in a clean
# environment with an empty DOCUCONF_FILE_ROOT, and checks its output and exit code.
# Usage: ./smoke.sh [path/to/Shop]   (default: builds it with swift build)
set -euo pipefail
cd "$(dirname "$0")"

bin=${1:-}
if [ -z "$bin" ]; then
    swift build
    bin="$(swift build --show-bin-path)/Shop"
fi
root=$(mktemp -d)
trap 'rm -rf "$root"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }

# The app reads contract.json from the current directory: this one.
run() { env -i PATH="$PATH" DOCUCONF_FILE_ROOT="$root" DATABASE_URL='postgres://shop:s3cr3t@db:5432/shop' "$@" "$bin"; }

# 1. The web role.
status=0
out=$(run DOCUCONF_ROLE=web ALLOWED_ORIGINS=https://shop.example 2>&1) || status=$?
echo "$out"
[ "$status" -eq 0 ] || fail "#1: want exit 0, got $status"
[ "$out" = "shop web: port 8080, origins https://shop.example" ] || fail "#1: unexpected output"
echo "ok: #1 web"

# 2. The worker role, which needs no ALLOWED_ORIGINS.
status=0
out=$(run DOCUCONF_ROLE=worker QUEUES=default,mail 2>&1) || status=$?
echo "$out"
[ "$status" -eq 0 ] || fail "#2: want exit 0, got $status"
[ "$out" = "shop worker: queues default,mail, webhooks off" ] || fail "#2: unexpected output"
echo "ok: #2 worker"

# 6. LOG_FORMAT=json makes LOG_SCHEMA_URL required: exit 1, nothing on standard output, and no secret printed.
status=0
stderr=$(mktemp)
out=$(run DOCUCONF_ROLE=worker QUEUES=default LOG_FORMAT=json 2>"$stderr") || status=$?
err=$(cat "$stderr")
rm -f "$stderr"
echo "$err"
[ "$status" -eq 1 ] || fail "#6: want exit 1, got $status"
[ -z "$out" ] || fail "#6: unexpected standard output: $out"
grep -qF 'docuconf: 1 configuration problem:' <<<"$err" || fail "#6: no problem count"
grep -qF '  - LOG_SCHEMA_URL [missing_required]: is required when LOG_FORMAT is "json"' <<<"$err" || fail "#6: no LOG_SCHEMA_URL missing_required"
case "$err" in *s3cr3t*) fail "#6: the secret was printed" ;; esac
echo "ok: #6 exits 1 with LOG_SCHEMA_URL missing_required"
