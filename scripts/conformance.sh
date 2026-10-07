#!/usr/bin/env bash
# Runs the shared conformance suite (docuconf-go conformance/cases.json) and
# the tests that `cue vet` exported contracts against the meta-schema
# (docuconf-go spec/cue). Not the full suite. Used by this repo's CI and by
# docuconf-go's downstream gate.
#
#   DOCUCONF_GO_DIR=/path/to/docuconf-go scripts/conformance.sh
#
# Needs swift and cue on PATH.
set -euo pipefail

: "${DOCUCONF_GO_DIR:?set DOCUCONF_GO_DIR to a docuconf-go checkout}"
DOCUCONF_GO_DIR=$(cd "$DOCUCONF_GO_DIR" && pwd)
export DOCUCONF_GO_DIR
export DOCUCONF_CONFORMANCE="${DOCUCONF_CONFORMANCE:-$DOCUCONF_GO_DIR/conformance/cases.json}"
export DOCUCONF_SPEC_CUE="${DOCUCONF_SPEC_CUE:-$DOCUCONF_GO_DIR/spec/cue}"
export DOCUCONF_REQUIRE_CONFORMANCE=1
export DOCUCONF_REQUIRE_VET=1

cd "$(dirname "$0")/.."
swift test --filter 'ConformanceTests|ExportTests|OverlayDeclarationTests|OverlayTests'
