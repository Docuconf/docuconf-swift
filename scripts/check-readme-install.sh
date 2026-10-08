#!/usr/bin/env bash
# Builds a fresh app from the README's Install block (a complete Package.swift) and the quickstart's main.swift,
# with the docuconf-swift dependency pinned to a pushed revision instead of the main branch.
# Usage: scripts/check-readme-install.sh <revision> [repository-url]
set -euo pipefail
rev=${1:?usage: check-readme-install.sh <revision> [repository-url]}
repo=$(cd "$(dirname "$0")/.." && pwd)
url=${2:-https://github.com/docuconf/docuconf-swift}
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

# The first ```swift block after "## Install".
awk '/^## Install/{f=1} f&&/^```swift$/{p=1;next} p&&/^```$/{exit} p' "$repo/README.md" > "$work/Package.swift"
grep -q 'branch: "main"' "$work/Package.swift" || { echo "the Install block does not depend on the main branch" >&2; exit 1; }
sed -i.bak -e "s|branch: \"main\"|revision: \"$rev\"|" -e "s|https://github.com/docuconf/docuconf-swift|$url|" "$work/Package.swift"
mkdir -p "$work/Sources/App"
cp "$repo/Examples/Quickstart/main.swift" "$work/Sources/App/main.swift"
cd "$work"
swift build
DATABASE_URL=postgres://localhost/app "$(swift build --show-bin-path)/App" | grep -q 'listening on :8080'
echo "ok: the README install block builds and runs at $rev"
