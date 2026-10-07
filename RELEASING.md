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
   For the first release (0.1.0), also switch the README's Install block from `branch: "main"` to
   `from: "0.1.0"`, and update `scripts/check-readme-install.sh` and `ReadmeTests` (which expect `branch: "main"`)
   to match. Make sure the macOS job in CI has passed: the package has not been built on macOS before.
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

## GitHub Packages and Releases

Swift packages need no registry: SwiftPM installs straight from this repository's tags, so there is nothing to put in
GitHub Packages. The GitHub copy of each release is the GitHub Release that the `release` job creates after the tests
pass. Its notes start with a link to the package's
[Swift Package Index page](https://swiftpackageindex.com/docuconf/docuconf-swift) (documentation and platform
compatibility) and the exact `.package(...)` line for that version, followed by GitHub's generated changelog. If the
release already exists (for example, a re-run), the job leaves it alone.

It needs no setup: the job uses only the workflow's own `GITHUB_TOKEN` (`contents: write`), which the `Docuconf`
organization allows unless it has restricted workflow permissions under Organization settings > Actions.

### Installing

No token is needed. In `Package.swift`:

```swift
.package(url: "https://github.com/docuconf/docuconf-swift.git", from: "0.1.0")
```

or in Xcode, File > Add Package Dependencies with the same URL.

## docuconf-go version

The spec, the CUE meta-schema and the shared conformance suite live in
[docuconf-go](https://github.com/Docuconf/docuconf-go). `.github/docuconf-go.ref` holds the full docuconf-go commit SHA
this SDK is tested against.

- **Push and pull request CI** check out docuconf-go at that commit, so a change in docuconf-go never breaks this
  repository's CI by surprise.
- **Bump pull requests.** `.github/workflows/docuconf-go-bump.yml` opens (or updates) a
  `build(deps): bump docuconf-go to <sha>` pull request on the `docuconf-go-bump` branch whenever docuconf-go's `main`
  moves: on a `docuconf-go-updated` dispatch from docuconf-go, and daily as a catch-up. CI on that pull request is the
  compatibility check; merge it when it is green. Run the workflow by hand (optionally with a `sha`) to pin a
  specific commit.
- **Nightly.** CI also runs every night against docuconf-go `main`, and can be started by hand with a
  `docuconf_go_ref` input to try any branch or commit.
- **`scripts/conformance.sh`** runs just the shared conformance suite and the `cue vet` tests against a docuconf-go
  checkout: `DOCUCONF_GO_DIR=../docuconf-go scripts/conformance.sh`. docuconf-go runs it on every pull request that
  touches the spec, so a breaking spec change shows up there before it merges.

Without the release GitHub App (`RELEASE_APP_ID` and `RELEASE_APP_PRIVATE_KEY`), the bump pull request is created with
`GITHUB_TOKEN`, which starts no workflows, so the bump workflow starts CI on the branch itself. That needs
**Settings → Actions → General → Allow GitHub Actions to create and approve pull requests**.
