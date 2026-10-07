# Releasing docuconf-swift

Swift packages have no upload step. SwiftPM resolves versions from **git tags** on the repository, and the
[Swift Package Index](https://swiftpackageindex.com) (SPI) watches registered repositories and picks up each new tag
by itself. A release is therefore a tag, plus the GitHub release that `.github/workflows/release.yml` creates.

Tags are plain semantic versions with no `v` prefix (`0.1.0`, `0.2.0-beta.1`), as SwiftPM and SPI expect.

## One-time setup

1. **Repository.** Publish this repository as `github.com/docuconf/docuconf-swift` (public).
2. **Swift Package Index.** Add the package by opening a pull request against
   [SwiftPackageIndex/PackageList](https://github.com/SwiftPackageIndex/PackageList) that adds
   `https://github.com/docuconf/docuconf-swift.git` to `packages.json` (or use the "Add a Package" form on the site).
   `.spi.yml` tells SPI to build documentation for the `Docuconf` and `DocuconfCore` targets.
3. **Protect tags** (optional). A tag ruleset limited to maintainers stops anyone else from creating a version.

No secret or token is needed: the release workflow only uses the repository's own `GITHUB_TOKEN` to create the
GitHub release.

## Each release

Releases are automated with [release-please](https://github.com/googleapis/release-please); see
[CONTRIBUTING.md](CONTRIBUTING.md#how-releases-happen) for the commit conventions it reads.

1. Merge the open release PR (`chore(main): release X.Y.Z`). It already updates `DocuconfSDK.version` in
   `Sources/DocuconfCore/Contract.swift` and `CHANGELOG.md`. The golden file and the example contracts do not need
   regenerating: their comparisons ignore `metadata.generator.version`.
2. release-please tags the merge commit `X.Y.Z` (no `v`) and creates the GitHub release with the changelog
   entries.
3. `release.yml` checks that the tag equals `DocuconfSDK.version` and runs the full test suite (including `cue vet`
   against the meta-schema from `docuconf/docuconf-go`). Its release job keeps the release release-please created,
   and creates one with generated notes only if none exists.
4. SPI usually lists the new version within minutes. Users get it with `.package(url: ..., from: "0.2.0")`.

If the release PR was created with `GITHUB_TOKEN` (no release GitHub App configured), the tag does not trigger
`release.yml` by itself, so `.github/workflows/release-please.yml` starts it with `gh workflow run`. To redo the
checks by hand: `gh workflow run release.yml --ref X.Y.Z`.

A pushed tag must never be moved or deleted: SwiftPM caches resolved revisions, and a moved tag breaks
`Package.resolved` files that pinned it. Fix a bad release with a new patch version.
