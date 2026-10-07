# docuconf-swift

The Swift SDK for [docuconf](https://github.com/docuconf): typed configuration contracts between an application and
the Kubernetes platform that runs it. It targets server-side Swift (Vapor, Hummingbird, plain SwiftNIO).

It extends Apple's [swift-configuration](https://github.com/apple/swift-configuration) rather than replacing it.
swift-configuration is the typed configuration library the Swift server ecosystem is converging on (released 1.0,
providers for environment variables, `.env` and JSON/YAML files, secret redaction), so it is the host library: values
are read through your `ConfigReader`, with its key names and parsing. It has no declaration, though: there is nowhere
to write a description, mark a secret, set a range or describe a mounted certificate. docuconf adds:

1. **A declaration** with the metadata swift-configuration lacks: descriptions, `secret`, constraints (ranges,
   lengths, RE2 patterns, enum values, URL schemes, list sizes) and file inputs (config files with a JSON Schema
   derived from your `Decodable` type, TLS key pairs, CA bundles, keystores, text and binary files).
2. **Boot validation.** Every problem with variables *and* mounted files is reported at once, with a stable error
   code, and written to `/dev/termination-log` so `kubectl describe pod` shows it. Secret values are never printed.
3. **Contract export.** The same declaration becomes a `contract.cue`, so the platform can reject bad configuration
   before it deploys.

> Status: v0.1, implementing [spec v1alpha1](https://github.com/docuconf/docuconf-go/blob/main/spec/SPEC.md).
> Expect breaking changes until v1. Licensed under the [MIT License](LICENSE).

**Example:** [`examples/orders`](examples/orders) is a small HTTP service with its exported `contract.cue`, the same
service every docuconf SDK ships.

## Install

```swift
// Package.swift
.package(url: "https://github.com/docuconf/docuconf-swift", from: "0.1.0"),
// target dependencies
.product(name: "Docuconf", package: "docuconf-swift"),
.product(name: "Configuration", package: "swift-configuration"),
```

Requires Swift 6.2 or later (swift-configuration's minimum) on Linux or macOS 15+.

## Example

```swift
import Configuration
import Docuconf

enum LogLevel: String, ConfigEnum { case debug, info, warn, error }

struct Routes: Decodable, Sendable {
    var routes: [Route]
    struct Route: Decodable, Sendable { var prefix: String; var upstream: URL }
}

struct GatewayConfig: DocuconfConfig {
    @Env("http.port", "HTTP listen port", .range(1...65535))
    var port = 8443

    @Env("database.url", "Primary Postgres connection string", .secret, .schemes("postgres", "postgresql"))
    var databaseURL: URL                       // no default: required

    @Env("log.level", "Minimum log level")
    var logLevel = LogLevel.info

    @Env("request.timeout", "Upstream request timeout", .range(.seconds(1) ... .seconds(300)))
    var requestTimeout: Duration = .seconds(30)

    @FileInput("routes", "Routing table: path prefixes and their upstreams",
               path: "/etc/gateway/routes/routes.json", .reload(.watch))
    var routes: ConfigFile<Routes>             // JSON Schema derived from Routes

    @FileInput("tls", "Certificate the gateway serves HTTPS with", path: "/etc/gateway/tls",
               .dnsNames("gateway.internal"), .keyAlgorithms(.ecdsa), .minRemaining(.seconds(30 * 24 * 3600)))
    var tls: TLSKeyPair
}

@main struct Gateway {
    static func main() async throws {
        Docuconf.exportIfRequested(GatewayConfig.self, name: "gateway")   // `docuconf-export` mode, see below

        let reader = ConfigReader(provider: EnvironmentVariablesProvider())
        let config = try await Docuconf.load(GatewayConfig.self, from: reader)

        // config.port is an Int, config.requestTimeout a Duration, config.routes.routes the decoded file,
        // config.tls.certificatePEM / privateKeyPEM the checked key pair, ready for swift-nio-ssl.
    }
}
```

The key (`http.port`) is a swift-configuration key, and the environment variable is the name
`EnvironmentVariablesProvider` reads for it (`HTTP_PORT`), so `reader.int(forKey: "http.port")` elsewhere in your app
reads the same value. A non-optional property with no initial value is required; an optional one (`URL?`,
`TLSKeyPair?`) is `nil` when unset or absent.

If anything is wrong, `load` throws a `ConfigurationError` listing every problem:

```
docuconf: 3 configuration problems:
  - HTTP_PORT [out_of_range]: is below min 1 (got "0")
  - DATABASE_URL [invalid_scheme]: scheme is not one of postgres, postgresql
  - tls [certificate_name_mismatch]: the certificate does not cover gateway.internal
```

A runnable version is in [`Examples/Gateway`](Examples/Gateway/main.swift) (`swift run GatewayExample`).

## Export the contract

`Docuconf.exportIfRequested` turns the executable into an exporter when its first argument is `docuconf-export`. It
reads no environment and checks no files, so it runs in CI without production values:

```sh
swift run Gateway docuconf-export --out contract.cue --app-version "$(git rev-parse HEAD)"
```

| Option | |
|---|---|
| `--out`, `-o` | File to write. Default: standard output. |
| `--app-version` | `metadata.appVersion`, such as the git SHA. |
| `--package` | CUE package name. Default: the service name with `-` replaced by `_`. |

Or call `try Contract.cue(for: GatewayConfig.self, name: "gateway")` from a test or a separate executable target.
The output is plain CUE data that unifies with the meta-schema's `contract.#Contract`, with variables and files
sorted by name. [`Examples/Gateway/contract.cue`](Examples/Gateway/contract.cue) is the example's contract, and
[`Tests/DocuconfCoreTests/Golden/gateway.cue`](Tests/DocuconfCoreTests/Golden/gateway.cue) uses every variable type
and every file input type.

## Declaring variables

| Swift type | Contract `type` | Rules |
|---|---|---|
| `String` | `string` | `.length(1...64)`, `.minLength`, `.maxLength`, `.pattern("^[a-z]+$")` |
| `Int` | `int` | `.range(1...65535)`, `.min`, `.max` |
| `Double` | `float` | `.range(0.0...1.0)`, `.min`, `.max` |
| `Bool` | `bool` | |
| `Duration` | `duration` | `.range(.seconds(1) ... .seconds(300))`, `.min`, `.max` |
| `URL` | `url` | `.schemes("postgres", "postgresql")` |
| a `ConfigEnum` (`String` raw values) | `enum` | the cases are the allowed values |
| `[String]`, `[Int]` | `list` | `.items(1...5)`, `.minItems`, `.maxItems` |
| `[Int32]`, `[UInt16]`, any fixed-width integer list | `list` of `int` | as above, plus `.itemRange(0...1023)`, `.itemMin`, `.itemMax` |
| a `JSONConfigValue` (`Codable` struct) | `json` | JSON Schema derived from the type |

Every variable also takes `.secret`, `.group("database")`, `.examples("eu-west-1")` and
`.deprecated("Use REQUEST_TIMEOUT", replacedBy: "REQUEST_TIMEOUT")`. The rules a type accepts are checked by the
compiler: `.schemes` on an `Int` does not build.

**Item bounds.** `.itemRange`, `.itemMin` and `.itemMax` bound every item of an integer list and are exported as
`itemMin` / `itemMax`; an item outside them is `out_of_range` at boot. A list of an integer type narrower than 64
bits exports the type's own range without any rule, so the platform never sends an item the app cannot hold:

```swift
@Env("shard.ids", "Shard ids this instance owns", .itemRange(0...1023)) var shardIDs: [UInt16] = [0]
// exports itemMin: 0, itemMax: 1023
@Env("listen.ports", "Extra ports to listen on") var ports: [UInt16]?
// exports itemMin: 0, itemMax: 65535
```

A rule bound outside the item type's range (`.itemRange(0...70000)` on `[UInt16]`) is a declaration error. Scalar
integers are `Int` only.

The declaration itself is checked before any value is read (`DeclarationError`): names, descriptions of at least 5
characters, defaults that break their own constraints, secrets with defaults or examples, patterns outside RE2
(lookaround, backreferences, possessive quantifiers), mount directories that clash or hide system directories, a
`pathEnv` that is also a variable, a `passwordVar` that is not a declared secret. Names that look like feature flags
(`ENABLE_`, `FF_`, `FEATURE_`) produce a warning (SPEC §10).

### Wire encodings and parsing

swift-configuration parses the values, so they mean the same to docuconf as to any other `ConfigReader` call:

- **Lists** use the `csv` encoding (`a,b`), which `EnvironmentVariablesProvider` splits on `,`. It trims whitespace
  around items; the platform never renders any.
- **Durations** use the `seconds` encoding (`90`, `1.5`): swift-configuration has no duration type, and a number of
  seconds is what it reads natively (`reader.double(forKey:)`). Contracts still hold Go-syntax durations (`1m30s`); the
  platform renders the number.
- **Booleans** accept `true`/`false` in any case, and also `yes`/`no`/`1`/`0`, as the host does.
- On top of the host, docuconf treats an empty string as unset for every type except `string` (SPEC §5), reports an
  integer (or integer list item) beyond the 64-bit range as `out_of_range` rather than `invalid_type`, rejects
  `NaN` and infinity, and never trims values. It warns when a secret ends in a newline (a Secret made with
  `--from-file`).
- **Patterns** are RE2, matched anywhere in the value. They run on Swift Regex with RE2's semantics: Unicode scalars,
  ASCII-only `\d`, `\w`, `\s`, `\b` and POSIX classes, `$` only at the end of the text, `(?P<name>...)` groups.

Values come from whatever providers your `ConfigReader` has. `Docuconf.load(GatewayConfig.self)` without a reader
uses `EnvironmentVariablesProvider` on the process environment with the declared secrets marked secret, and
`Docuconf.load(GatewayConfig.self, dotEnvPath: ".env")` adds a `.env` file for local development, which real
environment variables override.

## File inputs

| Property type | Contract `type` | Checked at boot | Rules |
|---|---|---|---|
| `ConfigFile<T: Decodable>` | `config` | parses as JSON or YAML (by extension, or `.format(.yaml)`) and decodes into `T` | schema from `T` |
| `TLSKeyPair` | `tls` | `tls.crt` and `tls.key` parse and match, validity, `minRemaining`, DNS names (one-label wildcards), key algorithm, chain to `ca.crt` | `.dnsNames`, `.keyAlgorithms`, `.minRemaining`, `.requireCA` |
| `CABundle` | `caBundle` | at least `minCertificates` parseable certificates | `.minCertificates(2)` |
| `Keystore` | `keystore` | PKCS#12 MAC or JKS digest verifies with the password variable | `.format(.jks)`, `.passwordVar("KEYSTORE_PASSWORD")` |
| `TextFile` | `text` | UTF-8, length and pattern | `.pattern`, `.length`, `.minLength`, `.maxLength` |
| `BinaryFile` | `binary` | size | |

Every input takes `.pathEnv("ROUTES_FILE")` (the path is read from that variable when it is set), `.maxSize(bytes)`,
`.reload(.watch)`, `.group`, `.deprecated` and, for config, text and binary files, `.secret`. TLS key pairs and
keystores are always secret.

**Schemas from code.** The JSON Schema for a `ConfigFile<T>` (or a `JSONConfigValue`) is derived from `T`'s
`Decodable` conformance by decoding it once with a recording decoder: properties read with `decode` are required,
`decodeIfPresent` optional, arrays and dictionaries record their element types, `CaseIterable` enums become `enum`
lists, and `URL`, `Date` and `UUID` become formatted strings. Swift has no runtime access to doc comments or custom
validation, so the derived schema has types and required properties only. Conform a type to `JSONSchemaProviding` to
supply a richer schema, and to `ValidatedConfig` to check invariants after decoding (reported as `schema_mismatch`).

TLS checks use [swift-certificates](https://github.com/apple/swift-certificates) and
[swift-crypto](https://github.com/apple/swift-crypto), which work the same on Linux and macOS. Keystores are opened
far enough to prove the password: the PKCS#12 MAC (SHA-1 to SHA-512, so both OpenSSL 3 defaults and `-legacy` files)
or the JKS keyed digest. PKCS#12 files that use PBMAC1 or public-key integrity are reported as unreadable.

**Reloading.** `.reload(.watch)` tells the platform it need not restart the pod when the source changes. Your app
keeps that promise by consuming the input's changes, which docuconf detects by polling the content (Kubernetes swaps a
symlink, so every file of the input is re-read together):

```swift
for await change in config.$routes.changes(every: .seconds(10)) {
    switch change {
    case .updated(let routes): router.replace(routes.value)   // passed every boot check
    case .rejected(let violations): logger.error("\(violations)")  // the old value stays in place
    }
}
```

## Config-file overlays

swift-configuration layers providers, and the first one with a value wins. An app that bakes a JSON or YAML file
into its image reads it with a `FileProvider` below the environment. An overlay (SPEC §4.7) is one more file that
the platform mounts between the two, so the order is baked-in file < overlay < environment. Declare it on the
configuration type:

```swift
struct GatewayConfig: DocuconfConfig {
    static let overlays = [
        ConfigOverlay("platform", "Settings the platform manages", path: "/etc/gateway/overlay/gateway.json"),
    ]

    @Env("http.port", "HTTP listen port", .range(1...65535)) var port = 8443
    // ...
}

let base = try await FileProvider<JSONSnapshot>(filePath: "/app/config/gateway.json")
let config = try await Docuconf.load(GatewayConfig.self, files: [base])
// providers, first match wins: environment, overlays, then `files`
```

If you compose your own `ConfigReader`, put `try await Docuconf.overlayProviders(for: GatewayConfig.self)` after the
environment provider and before your file providers. `Docuconf.load(_:from:)` reads only the providers the reader
has.

- **Format**: JSON or YAML, read with swift-configuration's `JSONSnapshot` and `YAMLSnapshot`. The format comes from
  the extension, or pass `format:`. TOML is not supported.
- **Keys**: the platform writes each value at its variable's swift-configuration key, split on `.`:
  `http.port` becomes `{"http": {"port": 8443}}`. The contract declares `keySeparator: "."`, and every variable gets
  a `configKey`, even when the key is already the variable name. The exception is `json` variables: a file
  snapshot splits a nested object into separate keys, so the app could not read one back. They get no `configKey`,
  and the platform has to supply them through the environment.
- **Values** are native JSON or YAML types, and docuconf checks them like environment values. A duration is a
  number of seconds (`90`, `1.5`), as the platform renders it; a string of seconds (`"90"`) is also accepted. A missing overlay file is fine. A file that
  does not parse is reported as `file_malformed`, together with every other problem.
- **Reload**: overlays are `reload: restart`, so a changed overlay rolls the pods. docuconf reads variables
  once, at boot, so declaring `.watch` is a declaration error.
- **Placement**: the platform mounts the overlay's directory, which hides whatever the image has there. The
  directory must not be a system directory or another input's mount, which is checked at declaration time. It must
  also not be the directory the executable runs from, which is checked at load (`LoadOptions.appDirectory`).
  `DOCUCONF_FILE_ROOT` is prepended to the overlay path, as for file inputs.

## Boot behaviour

- `DOCUCONF_FILE_ROOT` is prepended to every absolute file path, including one read from a `pathEnv` variable, for
  local development and tests.
- Violations are written to `/dev/termination-log` when it exists, or to `DOCUCONF_TERMINATION_LOG`.
- Error codes: `missing_required`, `invalid_type`, `out_of_range`, `pattern_mismatch`, `not_in_enum`,
  `invalid_scheme`, `too_few_items`, `too_many_items`, `file_missing`, `file_unreadable` (with an `fsGroup` hint),
  `file_too_large`, `file_malformed`, `schema_mismatch`, `certificate_invalid`, `certificate_expiring`,
  `certificate_name_mismatch`, `key_mismatch`, `keystore_unreadable`.
- Environment variables that are not declared are ignored.

### Injected secrets

Platforms often supply secrets at container start instead of in the pod spec: Bank-Vaults' `vault-env` resolves
values such as `vault:secret/data/db#url`, and wrappers such as `op run` resolve their own references. Nothing changes
in your code: docuconf reads the process environment as it is when the process starts, after injection, and validates
the injected values like any other. It never resolves a reference itself.

If the injector did not run, the app would receive the reference itself. A secret variable whose value starts with
`vault:`, `op://` or `ref+` therefore fails with `invalid_type`, naming the scheme but never the value:

```
DATABASE_URL [invalid_type]: holds an unresolved vault: reference; the injector that should resolve it did not run
```

## Mobile

iOS apps do not get per-environment configuration from Kubernetes: their configuration is compiled in, through
xcconfig files and `Info.plist`. This SDK does not solve that yet. It is split so a later build-time contract for iOS
can reuse the parts that matter:

- **`DocuconfCore`** holds the declaration model (`@Env`, `@FileInput`, `DocuconfConfig`), the declaration checks,
  JSON Schema derivation, value parsing and constraint checks, and the CUE contract writer. It imports nothing but
  Foundation, so it builds for iOS, and CI checks that it stays that way.
- **`Docuconf`** adds the server side: reading through swift-configuration, file and certificate checks with
  swift-crypto and swift-certificates, the termination log, reloading and the export command.

The likely shape for iOS is a contract exported at build time from the same declaration, with values checked in CI
against the xcconfig or plist of each build configuration, rather than at app launch.

## Contract-first mode

`ContractDocument` (in `DocuconfCore`) validates an environment against a contract given as JSON, with no Swift
declaration: for a hand-written `contract.cue` exported with `cue export contract.cue --out json`, or for tooling.
It parses every wire encoding in SPEC §5, whatever the contract records: lists as `csv` (with its `separator`),
`json` or `indexed` (`NAME__0`, `NAME__1`, ...), durations as `go`, `iso8601`, `seconds` or `timespan`. The checks
are the ones `Docuconf.load` runs on a declaration, and every violation is reported together.

```swift
let contract = try ContractDocument(json: Data(contentsOf: URL(fileURLWithPath: "contract.json")))
let values = try contract.load()   // or load(environment: [...]); throws ConfigurationError
if case .int(let port)? = values["PORT"] { print(port) }
```

Values are `ParsedValue`s (`values.json` gives them all as JSON, durations in canonical Go form). Unset optional
variables take their contract default, or are absent. Limits: a `json` variable must be valid JSON but is not
checked against its JSON Schema, and file inputs and overlays in the contract are ignored.

## Conformance

The test suite runs the shared conformance suite (SPEC §12) from docuconf-go through contract-first mode
(`Tests/DocuconfCoreTests/ConformanceTests.swift`). It reads `cases.json` from `DOCUCONF_CONFORMANCE`, or from a
`docuconf-go` checkout next to this repository, and is skipped when neither exists unless
`DOCUCONF_REQUIRE_CONFORMANCE=1` (as in CI):

```sh
DOCUCONF_CONFORMANCE=../docuconf-go/conformance/cases.json DOCUCONF_REQUIRE_CONFORMANCE=1 \
  swift test --filter ConformanceTests
```

A failing case is reported by its `id` (`int/below min`), which points at its YAML source in
`conformance/load/`. Capability tags this SDK skips:

| Tag | Why |
| --- | --- |
| `json-schema` | Contract-first mode has no JSON Schema validator; a `json` value is only checked to be JSON. (Declared `JSONConfigValue` types are checked by decoding into the Swift type.) |

`int64` is supported: `Int` is 64 bits on the platforms the suite runs on (Linux and macOS).

## Not supported yet

- Profiles (SPEC §4.4): swift-configuration has no profile convention, so baked-in config files are not exported as
  `profiles`. If you layer a JSON file provider under the environment, its values are not in the contract.
- TOML config files (no TOML decoder in the dependency set).
- Reloading config-file overlays (`reload: watch`): variables are read once, at boot.
- Reading `contract.cue` itself in contract-first mode: export it to JSON with `cue export` first.
- Markdown docs generated from the declaration (a SHOULD in the spec).
- The `ca.crt` chain check validates against the system clock, not `LoadOptions.now`.
- A Swift macro that generates the declaration. Property wrappers read by reflection (the approach
  swift-argument-parser uses) need no swift-syntax dependency and keep `DocuconfCore` light for iOS.

## Development

```sh
swift build
swift test
DOCUCONF_UPDATE_GOLDEN=1 swift test --filter ExportTests   # rewrite the golden contract, then review the diff
```

The export tests run `cue vet -c` on the generated contracts against the meta-schema in `docuconf-go/spec/cue`. Set
`DOCUCONF_SPEC_CUE` to that directory (a sibling `docuconf-go` checkout is found automatically) and have `cue` v0.17.1
on `PATH` or in `~/go/bin`. Without them the vet is skipped, unless `DOCUCONF_REQUIRE_VET=1`, as in CI. The conformance suite is found the same
way (see [Conformance](#conformance)). Test
certificates are generated by the tests with swift-certificates; the keystore fixtures come from
`scripts/make-keystore-fixtures.sh`.

**What has been verified.** The package was built and its tests run on Linux x86_64 with Swift 6.3.3 (the official
`swift:6.3.3-noble` image). It has not yet been built on macOS or for iOS; the macOS job in CI is the first place
that will happen.

Releases: see [RELEASING.md](RELEASING.md).

## License

MIT. See [LICENSE](LICENSE).
