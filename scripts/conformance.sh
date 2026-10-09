#!/usr/bin/env bash
# Runs the shared conformance suite (docuconf-go conformance/cases.json), the
# shared export check (conformance/export/golden.cue, compared by the docuconf
# CLI) and the tests that `cue vet` exported contracts against the meta-schema
# (docuconf-go spec/cue). Not the full suite. Used by this repo's CI and by
# docuconf-go's downstream gate.
#
#   DOCUCONF_GO_DIR=/path/to/docuconf-go scripts/conformance.sh
#
# Needs swift and cue on PATH. The docuconf CLI is taken from DOCUCONF_CLI or
# PATH, or else built from $DOCUCONF_GO_DIR/cmd/docuconf with go. Every case
# must run: the suite fails if any is skipped.
set -euo pipefail

: "${DOCUCONF_GO_DIR:?set DOCUCONF_GO_DIR to a docuconf-go checkout}"
DOCUCONF_GO_DIR=$(cd "$DOCUCONF_GO_DIR" && pwd)
export DOCUCONF_GO_DIR
export DOCUCONF_CONFORMANCE="${DOCUCONF_CONFORMANCE:-$DOCUCONF_GO_DIR/conformance/cases.json}"
export DOCUCONF_EXPORT_GOLDEN="${DOCUCONF_EXPORT_GOLDEN:-$DOCUCONF_GO_DIR/conformance/export/golden.cue}"
export DOCUCONF_SPEC_CUE="${DOCUCONF_SPEC_CUE:-$DOCUCONF_GO_DIR/spec/cue}"
export DOCUCONF_REQUIRE_CONFORMANCE=1
export DOCUCONF_REQUIRE_VET=1
export DOCUCONF_REQUIRE_EXPORT=1

if [ -z "${DOCUCONF_CLI:-}" ]; then
  if command -v docuconf >/dev/null 2>&1; then
    DOCUCONF_CLI=$(command -v docuconf)
  else
    cli_dir=$(mktemp -d)
    trap 'rm -rf "$cli_dir"' EXIT
    (cd "$DOCUCONF_GO_DIR/cmd/docuconf" && go build -o "$cli_dir/docuconf" .)
    DOCUCONF_CLI="$cli_dir/docuconf"
  fi
fi
export DOCUCONF_CLI

cd "$(dirname "$0")/.."
# The TLS trait builds the certificate and keystore checks the `files` cases need.
swift test --traits TLS --filter 'ConformanceTests|SharedExportTests|ExportTests|OverlayDeclarationTests|OverlayTests'
