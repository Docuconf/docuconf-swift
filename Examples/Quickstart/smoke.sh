#!/usr/bin/env bash
# Runs the README quickstart as the README shows it: a valid start, then a start with HTTP_PORT=0 and a misspelt
# DATABASE_URL, whose output must match expected-error.txt (the README's "See an error" block) exactly.
# Usage: Examples/Quickstart/smoke.sh [path/to/Quickstart]   (default: builds it with swift build)
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
cd "$here/../.."

bin=${1:-}
if [ -z "$bin" ]; then
    swift build --product Quickstart
    bin="$(swift build --show-bin-path)/Quickstart"
fi
fail() { echo "FAIL: $*" >&2; exit 1; }

out=$(env -i PATH="$PATH" DATABASE_URL='postgres://app:s3cr3t@localhost/app' "$bin" 2>&1) || fail "valid start failed: $out"
echo "$out"
grep -q 'listening on :8080' <<<"$out" || fail "no listening line"
grep -q '<redacted>' <<<"$out" || fail "print(config) does not redact the secret"
# The README's "Printing a configuration" block.
printed=$(awk '/^### Printing a configuration/{f=1} f&&/^```text$/{p=1;next} p&&/^```$/{exit} p' README.md)
grep -qxF "$printed" <<<"$out" || fail "print(config) differs from the README: $printed"
case "$out" in *s3cr3t*) fail "the secret was printed" ;; esac
echo "ok: valid start"

status=0
out=$(env -i PATH="$PATH" HTTP_PORT=0 DATABSE_URL='postgres://app:s3cr3t@localhost/app' "$bin" 2>&1) || status=$?
[ "$status" -eq 1 ] || fail "expected exit 1, got $status: $out"
diff -u "$here/expected-error.txt" <(printf '%s\n' "$out") || fail "the error output differs from expected-error.txt"
echo "ok: invalid start exits 1 with the README's output"
