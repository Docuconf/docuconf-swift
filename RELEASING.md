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

1. Update `DocuconfSDK.version` in `Sources/DocuconfCore/Contract.swift` (it is written into every exported contract
   as `metadata.generator.version`), regenerate the golden file and the example contract, and commit:
   ```sh
   DOCUCONF_UPDATE_GOLDEN=1 swift test --filter ExportTests
   swift run GatewayExample docuconf-export --out Examples/Gateway/contract.cue
   ```
2. Tag the commit and push the tag:
   ```sh
   git tag 0.2.0
   git push origin 0.2.0
   ```
3. `release.yml` checks that the tag equals `DocuconfSDK.version`, runs the full test suite (including `cue vet`
   against the meta-schema from `docuconf/docuconf-go`), and creates the GitHub release with generated notes. A tag
   with a hyphen (`0.2.0-beta.1`) becomes a pre-release; SwiftPM only resolves it for users who ask for
   pre-releases explicitly.
4. SPI usually lists the new version within minutes. Users get it with `.package(url: ..., from: "0.2.0")`.

A pushed tag must never be moved or deleted: SwiftPM caches resolved revisions, and a moved tag breaks
`Package.resolved` files that pinned it. Fix a bad release with a new patch version.
