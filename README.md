# docuconf-swift

The Swift SDK for [docuconf](https://github.com/docuconf): typed configuration contracts between an application and
the Kubernetes platform that runs it. You declare your configuration once, as a Swift struct. docuconf then checks the
environment and mounted files at boot, reports every problem at once, and exports a `contract.cue` that the platform
checks before it deploys.

It builds on Apple's [swift-configuration](https://github.com/apple/swift-configuration): values are read through a
`ConfigReader`, with its key names and parsing, so `reader.int(forKey: "http.port")` elsewhere in your app reads the
same value. It works with Hummingbird, Vapor or plain SwiftNIO.

> Status: v0.1, implementing [spec v1alpha1](https://github.com/docuconf/docuconf-go/blob/main/spec/SPEC.md).
> Expect breaking changes until v1. Licensed under the [MIT License](LICENSE).

Contents: [Install](#install) · [Declare and run](#declare-and-run) · [See an error](#see-an-error) ·
[Test your config](#test-your-config) · [Export the contract](#export-the-contract) · [Deploy](#deploy) ·
[Hummingbird](#with-hummingbird) · [Vapor](#with-vapor) · [Reference](#reference)

## Install

docuconf-swift is not released yet, so depend on its `main` branch. This is a complete `Package.swift` for an app:

<!-- checked-by: scripts/check-readme-install.sh -->
```swift
// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "App",
    platforms: [.macOS(.v15)],
    dependencies: [
        // Not released yet: use the main branch until the first tag (0.1.0), then `from: "0.1.0"`.
        .package(url: "https://github.com/docuconf/docuconf-swift", branch: "main"),
    ],
    targets: [
        .executableTarget(name: "App", dependencies: [
            .product(name: "Docuconf", package: "docuconf-swift"),
        ]),
    ]
)
```

Requires Swift 6.2 or later (swift-configuration's minimum), on Linux or macOS 15+. Once 0.1.0 is tagged, replace
`branch: "main"` with `from: "0.1.0"`.

Two optional additions:

- If you build your own `ConfigReader` (as the [Hummingbird](#with-hummingbird) section does), also add
  `.package(url: "https://github.com/apple/swift-configuration", from: "1.2.0")` and
  `.product(name: "Configuration", package: "swift-configuration")`.
- TLS key pairs, CA bundles and keystores are checked with swift-certificates and swift-crypto, which are built only
  with the package's `TLS` trait. Turn it on if you declare those file inputs:
  `.package(url: "https://github.com/docuconf/docuconf-swift", branch: "main", traits: ["TLS"])`. Without it, such a
  declaration fails at load with a message that says so.

## Declare and run

`Sources/App/main.swift`:

<!-- snippet: Examples/Quickstart/main.swift -->
```swift
import Docuconf
import Foundation

enum LogLevel: String, ConfigEnum { case debug, info, warn, error }

struct DatabaseConfig: Sendable {
    @Env("database.url", "Primary Postgres connection string", .secret, .schemes("postgres", "postgresql"))
    var url: URL                                    // no default: required

    @Env("database.pool.size", "Connections in the pool", .range(1...100))
    var poolSize = 10
}

struct AppConfig: DocuconfConfig {
    @Env("http.port", "HTTP listen port", .range(1...65535))
    var port = 8080

    @Env("log.level", "Minimum log level")
    var logLevel = LogLevel.info

    @Env("request.timeout", "Upstream request timeout", .range(.seconds(1) ... .seconds(300)))
    var requestTimeout: Duration = .seconds(30)     // REQUEST_TIMEOUT=30, in seconds

    var database = DatabaseConfig()                 // a nested struct groups variables
}

Docuconf.exportIfRequested(AppConfig.self, name: "quickstart")  // the `docuconf-export` command, see below
let config = await Docuconf.loadOrExit(AppConfig.self)           // on a problem: prints them all, exits 1

print("listening on :\(config.port), log level \(config.logLevel), pool of \(config.database.poolSize)")
print(config)                                                    // secrets print as <redacted>
```

Each `@Env` takes a swift-configuration key, a description and rules. The environment variable is the name
`EnvironmentVariablesProvider` reads for the key: `http.port` is `HTTP_PORT`, `database.pool.size` is
`DATABASE_POOL_SIZE`. A non-optional property with no initial value is required; an optional one (`URL?`) is `nil`
when unset. A nested struct, like `DatabaseConfig` here, groups variables; its `@Env` keys are used as written.

```sh
DATABASE_URL=postgres://localhost/app swift run App
```

This repository has the same program as [`Examples/Quickstart`](Examples/Quickstart/main.swift): run it with
`DATABASE_URL=postgres://localhost/app swift run Quickstart`.

## See an error

With `HTTP_PORT=0` and `DATABASE_URL` misspelt as `DATABSE_URL`, the app does not start. It prints every problem and
exits with status 1:

<!-- snippet: Examples/Quickstart/expected-error.txt -->
```text
docuconf: warning: DATABSE_URL is set but not declared; did you mean DATABASE_URL?
docuconf: 2 configuration problems:
  - HTTP_PORT [out_of_range]: is below min 1 (got "0")
  - DATABASE_URL [missing_required]: is required but not set (Primary Postgres connection string); DATABSE_URL is set, is it a typo?
```

- Each problem has a stable code (`out_of_range`, `missing_required`, ...), listed under [Boot behaviour](#boot-behaviour).
- The same text goes to `/dev/termination-log`, so `kubectl describe pod` shows it.
- Secret values never appear in a message, a warning, `print(config)` or `dump(config)`.
- `loadOrExit` prints no backtrace. Keep it in `main`: if `try await Docuconf.load(...)` throws out of top-level
  code or an `async throws` `main`, Swift crashes the process with a long backtrace.

## Test your config

`Docuconf.load(_:environment:)` loads from a dictionary. It never reads or changes the process environment, writes
no termination log and starts nothing in the background, so tests can run in parallel. With Swift Testing:

<!-- snippet: Tests/QuickstartTests/AppConfigTests.swift#testing -->
```swift
@testable import Quickstart
import Docuconf
import Testing

@Suite struct AppConfigTests {
    let valid = ["DATABASE_URL": "postgres://app@localhost/app"]

    @Test func defaults() async throws {
        let config = try await Docuconf.load(AppConfig.self, environment: valid)
        #expect(config.port == 8080)
        #expect(config.database.poolSize == 10)
    }

    @Test func rejectsPortZero() async throws {
        let error = await #expect(throws: ConfigurationError.self) {
            try await Docuconf.load(AppConfig.self, environment: valid.merging(["HTTP_PORT": "0"]) { $1 })
        }
        #expect(error?.violations.map(\.code) == [.outOfRange])
    }

    @Test func contractListsEveryVariable() throws {
        let names = try Declaration(AppConfig.self).vars.map(\.name)
        #expect(names.contains("DATABASE_POOL_SIZE"))
    }
}
```

The same call builds a configuration for handler tests. `load(_:environment:fileRoot:)` also checks file inputs
under a test directory. To load through a reader, pass one built from swift-configuration's `InMemoryProvider` to
`Docuconf.load(_:from:)`.

## Export the contract

`Docuconf.exportIfRequested` turns the executable into an exporter when its first argument is `docuconf-export`. It
reads no environment and checks no files, so it runs in CI without production values:

```sh
swift run App docuconf-export --out contract.cue --app-version "$(git rev-parse HEAD)"
```

| Option | |
|---|---|
| `--out`, `-o` | File to write. Default: standard output. |
| `--app-version` | `metadata.appVersion`, such as the git SHA. |
| `--package` | CUE package name. Default: the service name with `-` replaced by `_`. |
| `--help` | Usage. |

Commit `contract.cue` and have CI re-export it and fail on a diff, as this repository does for its examples. You can
also call `try Contract.cue(for: AppConfig.self, name: "app")` from a test.

## Deploy

The platform never runs the app to learn what it needs: it reads `contract.cue`. The
[docuconf CLI](https://github.com/docuconf/docuconf-go/tree/main/cmd/docuconf) checks a deployment's values against
the contract with `docuconf vet`, and turns them into the container's environment with `docuconf render`. The
[Helm chart](https://github.com/docuconf/docuconf-go/tree/main/helm/docuconf) does the same at `helm install` time.
[`Examples/Orders`](Examples/Orders) is a small HTTP service with its exported contract, the same service every
docuconf SDK ships, with a smoke test.

## With Hummingbird

Hummingbird apps already build a `ConfigReader`: pass the same reader to `loadOrExit`, and feed the validated values
into `ApplicationConfiguration`. Inputs declared `.reload(.watch)` promise the platform that the app picks up
changes; a small `Service` in the app's `ServiceGroup` keeps that promise and stops on graceful shutdown.

<!-- snippet: Examples/HelloHummingbird/Sources/App/main.swift#hummingbird -->
```swift
import Configuration
import Docuconf
import Foundation
import Hummingbird
import Logging
import ServiceLifecycle

struct Greeting: Decodable, Sendable { var text: String }

struct HelloConfig: DocuconfConfig {
    @Env("http.host", "Address to listen on") var host = "0.0.0.0"
    @Env("http.port", "HTTP listen port", .range(1...65535)) var port = 8080
    @Env("database.url", "Primary Postgres connection string", .secret, .schemes("postgres")) var databaseURL: URL
    @FileInput("greeting", "Greeting served on /", path: "/etc/hello/greeting.json", .reload(.watch))
    var greeting: ConfigFile<Greeting>
}

/// Keeps the `.reload(.watch)` promise: applies changes to the greeting while the app runs.
struct GreetingReloader: Service {
    let config: HelloConfig
    let logger: Logger

    func run() async {
        for await change in config.$greeting.changes(every: .seconds(5)).cancelOnGracefulShutdown() {
            switch change {
            case .updated(let greeting): logger.info("greeting is now \(greeting.text)")
            case .rejected(let violations): logger.error("kept the old greeting: \(violations)")
            }
        }
    }
}

Docuconf.exportIfRequested(HelloConfig.self, name: "hello")

// One ConfigReader for docuconf and the rest of the app.
let reader = ConfigReader(provider: EnvironmentVariablesProvider())
let config = await Docuconf.loadOrExit(HelloConfig.self, from: reader)
let logger = Logger(label: "hello")

let router = Router()
router.get("/") { _, _ in config.greeting.text }  // always the latest content that passed its checks
router.get("/healthz") { _, _ in "ok" }

var app = Application(
    router: router,
    configuration: .init(address: .hostname(config.host, port: config.port)),
    logger: logger
)
app.addServices(GreetingReloader(config: config, logger: logger))
try await app.runService()
```

The full package is [`Examples/HelloHummingbird`](Examples/HelloHummingbird); CI builds it and runs its smoke test, which
changes the greeting file while the app runs. It needs `hummingbird`, `swift-configuration` and
`swift-service-lifecycle` as dependencies.

## With Vapor

Vapor reads its environment with `Environment.get` rather than swift-configuration, so call `loadOrExit` without a
reader, which reads the process environment. Call it **after** `Application.make`: that is where Vapor loads `.env`
and `.env.<environment>` into the process environment, and loading earlier would miss local values from them. Keep
the configuration in `app.storage` so route handlers can reach it.

<!-- snippet: Examples/HelloVapor/Sources/App/entrypoint.swift#vapor -->
```swift
import Docuconf
import Vapor

struct HelloConfig: DocuconfConfig {
    @Env("port", "HTTP listen port", .range(1...65535)) var port = 8080
    @Env("database.url", "Primary Postgres connection string", .secret, .schemes("postgres")) var databaseURL: URL
    @Env("greeting", "Greeting served on /", .length(1...200)) var greeting = "hello"
}

extension Application {
    private struct HelloConfigKey: StorageKey { typealias Value = HelloConfig }

    /// The validated configuration, for route handlers: `req.application.config.greeting`.
    var config: HelloConfig {
        get { storage[HelloConfigKey.self]! }
        set { storage[HelloConfigKey.self] = newValue }
    }
}

@main enum Entrypoint {
    static func main() async throws {
        Docuconf.exportIfRequested(HelloConfig.self, name: "hello")  // before Vapor parses the arguments

        var env = try Environment.detect()
        try LoggingSystem.bootstrap(from: &env)
        // Application.make loads .env and .env.<environment> into the process environment,
        // so load the configuration after it, or local values from .env are not seen.
        let app = try await Application.make(env)
        app.config = await Docuconf.loadOrExit(HelloConfig.self)
        app.http.server.configuration.port = app.config.port

        app.get { req in req.application.config.greeting }
        app.get("healthz") { _ in "ok" }

        do {
            try await app.execute()
        } catch {
            app.logger.report(error: error)
            try? await app.asyncShutdown()
            throw error
        }
        try await app.asyncShutdown()
    }
}
```

The full package is [`Examples/HelloVapor`](Examples/HelloVapor). Its smoke test, run in CI, supplies `DATABASE_URL` only
through a `.env` file, which proves the order above. Run the exporter as `swift run App docuconf-export`.

Both framework sections are tested recipes rather than `DocuconfHummingbird` / `DocuconfVapor` modules: the
integration is a handful of lines, and a module would make every docuconf user resolve both frameworks.

# Reference

## Declaring variables

| Swift type | Contract `type` | Rules |
|---|---|---|
| `String` | `string` | `.length(1...64)`, `.minLength`, `.maxLength`, `.pattern("^[a-z]+$")` |
| `Int` | `int` | `.range(1...65535)` or `.range(1..<65536)`, `.min`, `.max` |
| `Int8` ... `Int64`, `UInt8` ... `UInt32` | `int` | as `Int`; a type narrower than 64 bits exports its own range as `min` / `max` |
| `Double` | `float` | `.range(0.0...1.0)`, `.min`, `.max` |
| `Bool` | `bool` | |
| `Duration` | `duration` | `.range(.seconds(1) ... .seconds(300))`, `.min`, `.max` |
| `URL` | `url` | `.schemes("postgres", "postgresql")`, `.maxLength` |
| a `ConfigEnum` (`String` raw values) | `enum` | the cases are the allowed values |
| `[String]`, `[Int]` | `list` | `.items(1...5)`, `.minItems`, `.maxItems` |
| `[String]` | `list` of `string` | as above, plus `.itemLength(2...4)`, `.itemMinLength`, `.itemMaxLength` |
| `[Int32]`, `[UInt16]`, any fixed-width integer list | `list` of `int` | as above, plus `.itemRange(0...1023)`, `.itemMin`, `.itemMax` |
| a `JSONConfigValue` (`Codable` struct) | `json` | JSON Schema derived from the type; `.maxLength` |

`Float` is not supported (declare `Double`); the compiler says so.

Every variable also takes `.secret`, `.group("database")`, `.examples("eu-west-1")` and
`.deprecated("Use REQUEST_TIMEOUT", replacedBy: "REQUEST_TIMEOUT")`. The description may be labelled:
`@Env("http.port", description: "HTTP listen port") var port = 8080`. The rules a type accepts are checked by the
compiler: `.schemes` on an `Int` does not build.

**Descriptions and details.** Every input needs a description of at least 5 characters, and may have `details`:
CommonMark used only in generated docs, never at runtime, at most 4000 characters. A property wrapper cannot see the
`///` comment above it, so write the doc comment as the description argument instead, as a multi-line string: its
first paragraph is the description, on one line, and the rest the details. DocC syntax becomes CommonMark: symbol
links (` ``Name`` `) become code spans, `<doc:Article>` the article's name, callouts such as `- Note:` and
`- Important:` bold labels, and `- Parameter`, `- Returns:` and `- Throws:` are dropped. `.details("...")` sets the
details explicitly, on a variable or a file input:

<!-- snippet: Tests/DocuconfTests/ReadmeSnippets.swift#details -->
```swift
@Env("request.timeout", """
    Upstream request timeout

    The gateway gives up on an upstream after this long and answers 504. Keep it below the load
    balancer's idle timeout; see ``LoadBalancer/idleTimeout``.

    - Note: Read in seconds, as `REQUEST_TIMEOUT=30`.
    """, .range(.seconds(1) ... .seconds(300)))
var requestTimeout: Duration = .seconds(30)

@Env("worker.count", "Number of request workers", .details("Each holds one database connection.")) var workers = 4
```

`REQUEST_TIMEOUT` exports the description `Upstream request timeout`, and the rest of the text as its details, with
the symbol link as a code span and the note as `**Note:**`. Blank details, or details
over 4000 characters (Unicode scalars), are a `DeclarationError`, as a missing description is. Contract-first mode
accepts `details` and ignores them. `docuconf docs` (in the [docuconf CLI](https://github.com/docuconf/docuconf-go))
generates CONFIG.md and CONFIG.agents.md from the exported contract; the SDK only exports the text.

**Nested structs.** A plain stored struct property (`var database = DatabaseConfig()`) is searched for inputs, to any
depth, and its variables are read, checked and exported like the others. Inputs inside an optional, a collection, an
enum or a class are a `DeclarationError` naming the property, since docuconf could not read them reliably.

**Item bounds.** `.itemRange`, `.itemMin` and `.itemMax` bound every item of an integer list and are exported as
`itemMin` / `itemMax`; an item outside them is `out_of_range` at boot. A list of an integer type narrower than 64
bits exports the type's own range without any rule, so the platform never sends an item the app cannot hold:

<!-- snippet: Tests/DocuconfTests/ReadmeSnippets.swift#item-bounds -->
```swift
@Env("shard.ids", "Shard ids this instance owns", .itemRange(0...1023)) var shardIDs: [UInt16] = [0]
// exports itemMin: 0, itemMax: 1023
@Env("listen.ports", "Extra ports to listen on") var ports: [UInt16]?
// exports itemMin: 0, itemMax: 65535
```

A rule bound outside the item type's range (`.itemRange(0...70000)` on `[UInt16]`) is a declaration error.

**Lengths** count characters, meaning Unicode scalars (`unicodeScalars.count`), never bytes or UTF-16 units or
grapheme clusters: `"日本"` is 2 and `"ZÜ01"` fits `.itemMaxLength(4)`. `.maxLength` on a `URL` bounds the string as
given; on a `JSONConfigValue` it bounds the wire string, the raw value as received at boot (whitespace included) and
the compact JSON for a default. `.itemLength`, `.itemMinLength` and `.itemMaxLength` bound each item of a string list
after it is split, so separators never count. A value outside a length limit is `out_of_range`, and a secret reports
its length, never its value:

<!-- snippet: Tests/DocuconfTests/ReadmeSnippets.swift#lengths -->
```swift
@Env("callback.url", "Where to report each run", .schemes("https"), .maxLength(40)) var callback: URL?
@Env("branches", "Branch codes, two to four characters each", .itemLength(2...4)) var branches: [String] = ["BE"]
```

**Declaration checks.** The declaration itself is checked before any value is read (`DeclarationError`): names,
descriptions of at least 5 characters, defaults that break their own constraints, secrets with defaults or examples,
patterns outside RE2 (lookaround, backreferences, possessive quantifiers), mount directories that clash or hide system
directories, a `pathEnv` that is also a variable, a `passwordVar` that is not a declared secret, inputs nested where
they cannot be read. Names that look like feature flags (`ENABLE_`, `FF_`, `FEATURE_`) produce a warning (SPEC §10).

### Wire encodings and parsing

swift-configuration parses the values, so they mean the same to docuconf as to any other `ConfigReader` call:

- **Durations** use the `seconds` encoding: `REQUEST_TIMEOUT=30` or `1.5`. swift-configuration has no duration type,
  and a number of seconds is what it reads natively (`reader.double(forKey:)`). The contract still shows defaults
  and bounds in Go syntax (`30s`, `1m30s`), and the platform renders the number. A Go-style value in the environment
  is rejected with the number to write instead: `REQUEST_TIMEOUT [invalid_type]: is not a number of seconds;
  durations are read as plain seconds, so write 30 (got "30s")`.
- **Lists** use the `csv` encoding (`a,b`), which `EnvironmentVariablesProvider` splits on `,`. It trims whitespace
  around items; the platform never renders any.
- **Booleans** accept `true`/`false` in any case, and also `yes`/`no`/`1`/`0`, as the host does.
- On top of the host, docuconf treats an empty string as unset for every type except `string` (SPEC §5), reports an
  integer (or integer list item) beyond the 64-bit range as `out_of_range` rather than `invalid_type`, rejects
  `NaN` and infinity, and never trims values. It warns when a secret ends in a newline (a Secret made with
  `--from-file`).
- **Patterns** are RE2, matched anywhere in the value. They run on Swift Regex with RE2's semantics: Unicode scalars,
  ASCII-only `\d`, `\w`, `\s`, `\b` and POSIX classes, `$` only at the end of the text, `(?P<name>...)` groups.

Values come from whatever providers your `ConfigReader` has. `Docuconf.load(AppConfig.self)` (and `loadOrExit`)
without a reader uses `EnvironmentVariablesProvider` on the process environment with the declared secrets marked
secret, and `Docuconf.load(AppConfig.self, dotEnvPath: ".env")` adds a `.env` file for local development, which real
environment variables override.

### Printing a configuration

`print(config)`, string interpolation, `dump(config)` and debuggers show each input's value, and `<redacted>` for a
secret (TLS key pairs and keystores are always secret). The quickstart prints:

<!-- checked-by: Examples/Quickstart/smoke.sh -->
```text
AppConfig(_port: 8080, _logLevel: Quickstart.LogLevel.info, _requestTimeout: 30.0 seconds, database: Quickstart.DatabaseConfig(_url: <redacted>, _poolSize: 10))
```

The property-wrapper storage shows as `_port`. They never show the declaration's internals.

## File inputs

| Property type | Contract `type` | Checked at boot | Rules |
|---|---|---|---|
| `ConfigFile<T: Decodable>` | `config` | parses as JSON or YAML (by extension, or `.format(.yaml)`) and decodes into `T` | schema from `T` |
| `TLSKeyPair` (TLS trait) | `tls` | `tls.crt` and `tls.key` parse and match, validity, `minRemaining`, DNS names (one-label wildcards), key algorithm, chain to `ca.crt` | `.dnsNames`, `.keyAlgorithms`, `.minRemaining`, `.requireCA` |
| `CABundle` (TLS trait) | `caBundle` | at least `minCertificates` parseable certificates | `.minCertificates(2)` |
| `Keystore` (TLS trait) | `keystore` | PKCS#12 MAC or JKS digest verifies with the password variable | `.format(.jks)`, `.passwordVar("KEYSTORE_PASSWORD")` |
| `TextFile` | `text` | UTF-8, length and pattern | `.pattern`, `.length`, `.minLength`, `.maxLength` |
| `BinaryFile` | `binary` | size | |

Every input takes `.pathEnv("ROUTES_FILE")` (the path is read from that variable when it is set), `.maxSize(bytes)`,
`.reload(.watch)`, `.group`, `.deprecated` and, for config, text and binary files, `.secret`. TLS key pairs and
keystores are always secret. Locally, set `DOCUCONF_FILE_ROOT` to a directory that mirrors the container's paths.

This is the gateway from [`Examples/Gateway`](Examples/Gateway/main.swift):

<!-- snippet: Examples/Gateway/main.swift#gateway-config -->
```swift
enum LogLevel: String, ConfigEnum { case debug, info, warn, error }

struct Routes: Decodable, Sendable {
    var routes: [Route]
    struct Route: Decodable, Sendable { var prefix: String; var upstream: URL }
}

struct GatewayConfig: DocuconfConfig {
    @Env("http.port", "HTTP listen port", .range(1...65535))
    var port = 8443

    @Env("database.url", "Primary Postgres connection string", .secret, .schemes("postgres", "postgresql"))
    var databaseURL: URL

    @Env("log.level", "Minimum log level")
    var logLevel = LogLevel.info

    @Env("request.timeout", "Upstream request timeout", .range(.seconds(1) ... .seconds(300)))
    var requestTimeout: Duration = .seconds(30)

    @FileInput("routes", "Routing table: path prefixes and their upstreams",
               path: "/etc/gateway/routes/routes.json", .reload(.watch))
    var routes: ConfigFile<Routes>             // JSON Schema derived from Routes

    @FileInput("tls", "Certificate the gateway serves HTTPS with", path: "/etc/gateway/tls",
               .dnsNames("gateway.internal"), .keyAlgorithms(.ecdsa), .minRemaining(.seconds(30 * 24 * 3600)))
    var tls: TLSKeyPair                        // needs the TLS trait
}
```

Run it from this repository. `make-dev-tls.sh` writes a self-signed development certificate under `dev-root`:

```sh
Examples/Gateway/make-dev-tls.sh
DOCUCONF_FILE_ROOT=Examples/Gateway/dev-root DATABASE_URL=postgres://localhost/gw swift run --traits TLS GatewayExample
```

**Schemas from code.** The JSON Schema for a `ConfigFile<T>` (or a `JSONConfigValue`) is derived from `T`'s
`Decodable` conformance by decoding it once with a recording decoder: properties read with `decode` are required,
`decodeIfPresent` optional, arrays and dictionaries record their element types, `CaseIterable` enums become `enum`
lists, and `URL`, `Date` and `UUID` become formatted strings. Swift has no runtime access to doc comments or custom
validation, so the derived schema has types and required properties only. Conform a type to `JSONSchemaProviding` to
supply a richer schema, and to `ValidatedConfig` to check invariants after decoding (reported as `schema_mismatch`;
for a secret input, the validator's text is replaced by a generic message, since it could quote the content).

**TLS trait.** TLS checks use [swift-certificates](https://github.com/apple/swift-certificates) and
[swift-crypto](https://github.com/apple/swift-crypto), which work the same on Linux and macOS, and are built only with
the `TLS` trait (see [Install](#install)). Keystores are opened far enough to prove the password: the PKCS#12 MAC
(SHA-1 to SHA-512, so both OpenSSL 3 defaults and `-legacy` files) or the JKS keyed digest. PKCS#12 files that use
PBMAC1 or public-key integrity are reported as unreadable. The types (`TLSKeyPair`, ...) are always available, so a
declaration compiles and exports without the trait; loading it fails with a `DeclarationError` that says to turn the
trait on.

**Reloading.** `.reload(.watch)` tells the platform it need not restart the pod when the source changes. Your app
keeps that promise by consuming the input's changes, which docuconf detects by polling the content (Kubernetes swaps a
symlink, so every file of the input is re-read together). In a service, run the loop in a `Service`, as in
[With Hummingbird](#with-hummingbird):

<!-- snippet: Examples/Gateway/main.swift#reload -->
```swift
for await change in config.$routes.changes(every: .seconds(10)) {
    switch change {
    case .updated(let routes): print("new routes: \(routes.routes.map(\.prefix))")  // passed every boot check
    case .rejected(let violations): print("kept the old routes: \(violations)")      // the old value stays
    }
}
```

## Config-file overlays

swift-configuration layers providers, and the first one with a value wins. An app that bakes a JSON or YAML file
into its image reads it with a `FileProvider` below the environment. An overlay (SPEC §4.7) is one more file that
the platform mounts between the two, so the order is baked-in file < overlay < environment. Declare it on the
configuration type:

<!-- snippet: Tests/DocuconfTests/ReadmeSnippets.swift#overlays -->
```swift
struct OverlaidConfig: DocuconfConfig {
    static let overlays = [
        ConfigOverlay("platform", "Settings the platform manages", path: "/etc/gateway/overlay/gateway.json"),
    ]

    @Env("http.port", "HTTP listen port", .range(1...65535)) var port = 8443
}

let base = try await FileProvider<JSONSnapshot>(filePath: "/app/config/gateway.json")
let config = await Docuconf.loadOrExit(OverlaidConfig.self, files: [base])
// providers, first match wins: environment, overlays, then `files`
```

If you compose your own `ConfigReader`, put `try await Docuconf.overlayProviders(for: OverlaidConfig.self)` after the
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
  number of seconds (`90`, `1.5`), as the platform renders it; a string of seconds (`"90"`) is also accepted. A
  missing overlay file is fine. A file that does not parse is reported as `file_malformed`, together with every other
  problem.
- **Reload**: overlays are `reload: restart`, so a changed overlay rolls the pods. docuconf reads variables
  once, at boot, so declaring `.watch` is a declaration error.
- **Placement**: the platform mounts the overlay's directory, which hides whatever the image has there. The
  directory must not be a system directory or another input's mount, which is checked at declaration time. It must
  also not be the directory the executable runs from, which is checked at load (`LoadOptions.appDirectory`).
  `DOCUCONF_FILE_ROOT` is prepended to the overlay path, as for file inputs.

## Boot behaviour

- `DOCUCONF_FILE_ROOT` is prepended to every absolute file path, including one read from a `pathEnv` variable, for
  local development and tests.
- Violations are written to `/dev/termination-log` when it exists, or to `DOCUCONF_TERMINATION_LOG` (an empty value
  writes no log).
- A set variable that is not declared but is within two edits of a declared name (one edit for names of four
  characters or fewer, so `HOME` is not taken for `HOST`) produces a warning naming both. Other undeclared variables
  are ignored.
- Error codes: `missing_required`, `invalid_type`, `out_of_range`, `pattern_mismatch`, `not_in_enum`,
  `invalid_scheme`, `too_few_items`, `too_many_items`, `file_missing`, `file_unreadable` (with an `fsGroup` hint),
  `file_too_large`, `file_malformed`, `schema_mismatch`, `certificate_invalid`, `certificate_expiring`,
  `certificate_name_mismatch`, `key_mismatch`, `keystore_unreadable`.
- `Docuconf.load` throws `ConfigurationError` (every violation) or `DeclarationError`; `Docuconf.loadOrExit` prints
  either and exits 1.

### Injected secrets

Platforms often supply secrets at container start instead of in the pod spec: Bank-Vaults' `vault-env` resolves
values such as `vault:secret/data/db#url`, and wrappers such as `op run` resolve their own references. Nothing changes
in your code: docuconf reads the process environment as it is when the process starts, after injection, and validates
the injected values like any other. It never resolves a reference itself.

If the injector did not run, the app would receive the reference itself. A secret variable whose value starts with
`vault:`, `op://` or `ref+` therefore fails with `invalid_type`, naming the scheme but never the value:

<!-- checked-by: Tests/DocuconfTests/ReadmeTests.swift -->
```text
DATABASE_URL [invalid_type]: holds an unresolved vault: reference; the injector that should resolve it did not run
```

## Mobile

iOS apps do not get per-environment configuration from Kubernetes: their configuration is compiled in, through
xcconfig files and `Info.plist`. This SDK does not solve that yet. It is split so a later build-time contract for iOS
can reuse the parts that matter:

- **`DocuconfCore`** holds the declaration model (`@Env`, `@FileInput`, `DocuconfConfig`), the declaration checks,
  JSON Schema derivation, value parsing and constraint checks, and the CUE contract writer. It imports nothing but
  Foundation, so it builds for iOS, and CI checks that it stays that way.
- **`Docuconf`** adds the server side: reading through swift-configuration, file checks (and, with the `TLS` trait,
  certificate and keystore checks with swift-crypto and swift-certificates), the termination log, reloading and the
  export command.

## Contract-first mode

`ContractDocument` (in `DocuconfCore`) validates an environment against a contract given as JSON, with no Swift
declaration: for a hand-written `contract.cue` exported with `cue export contract.cue --out json`, or for tooling.
It parses every wire encoding in SPEC §5, whatever the contract records: lists as `csv` (with its `separator`),
`json` or `indexed` (`NAME__0`, `NAME__1`, ...), durations as `go`, `iso8601`, `seconds` or `timespan`. The checks
are the ones `Docuconf.load` runs on a declaration, and every violation is reported together.

<!-- snippet: Tests/DocuconfTests/ReadmeSnippets.swift#contract-first -->
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
swift test --traits TLS        # everything, including the TLS and keystore checks
swift test                     # the default build, without the TLS trait
DOCUCONF_UPDATE_GOLDEN=1 swift test --filter ExportTests   # rewrite the golden contract, then review the diff
```

The export tests run `cue vet -c` on the generated contracts against the meta-schema in `docuconf-go/spec/cue`. Set
`DOCUCONF_SPEC_CUE` to that directory (a sibling `docuconf-go` checkout is found automatically) and have `cue` v0.17.1
on `PATH` or in `~/go/bin`. Without them the vet is skipped, unless `DOCUCONF_REQUIRE_VET=1`, as in CI. The
conformance suite is found the same way (see [Conformance](#conformance)). Test certificates are generated by the
tests with swift-certificates; the keystore fixtures come from `scripts/make-keystore-fixtures.sh`.

**README snippets are checked.** Every `swift` and `text` block in this README is preceded by a
`<!-- snippet: file#region -->` marker, and `ReadmeTests` fails unless the block is exactly that file or region. The
files are compiled in CI: the quickstart and its test, the gateway, `Tests/DocuconfTests/ReadmeSnippets.swift` and the
Hummingbird and Vapor packages. The install block is built against the pushed commit by
`scripts/check-readme-install.sh`, and the "See an error" output is compared with the real output by
`Examples/Quickstart/smoke.sh`.

**What has been verified.** The package was built and its tests run on Linux x86_64 with Swift 6.3.3 (the official
`swift:6.3.3-noble` image). It has not yet been built on macOS or for iOS; the macOS job in CI is the first place
that will happen, and it should pass before the first release.

Releases: see [RELEASING.md](RELEASING.md).

## License

MIT. See [LICENSE](LICENSE).
