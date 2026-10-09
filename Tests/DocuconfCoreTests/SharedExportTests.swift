import CueTestSupport
import DocuconfCore
import Foundation
import Testing

// The shared export fixture (docuconf-go conformance/export/fixture.yaml, SPEC §11.2 item 3), declared in Swift.
// Its export must match conformance/export/golden.cue as data, compared by `docuconf conformance export`.

enum FixtureLogLevel: String, ConfigEnum {
    case debug, info, warn, error
}

struct FixtureRateLimits: JSONConfigValue, JSONSchemaProviding {
    var perMinute: Int
    var burst: Int?

    static var jsonSchema: JSONValue {
        [
            "type": "object", "required": ["perMinute"], "additionalProperties": false,
            "properties": ["perMinute": ["type": "integer", "minimum": 1], "burst": ["type": "integer", "minimum": 0]],
        ]
    }
}

struct FixtureSettings: Decodable, Sendable, JSONSchemaProviding {
    var name: String
    var replicas: Int
    var tags: [String]?

    static var jsonSchema: JSONValue {
        [
            "type": "object", "required": ["name", "replicas"], "additionalProperties": false,
            "properties": [
                "name": ["type": "string", "minLength": 1], "replicas": ["type": "integer", "minimum": 1],
                "tags": ["type": "array", "items": ["type": "string"]],
            ],
        ]
    }
}

struct FixtureConfig: DocuconfConfig {
    @Env("app.name", "Service name, used in logs and metrics", .details("Lower case, as a DNS label allows."),
         .length(2...40), .pattern("^[a-z][a-z0-9-]*$"), .group("general"), .examples("orders", "billing"))
    var appName = "orders"

    @Env("database.url", "Primary Postgres connection string", .secret, .schemes("postgres", "postgresql"), .maxLength(2048),
         .group("database"))
    var databaseURL: URL

    @Env("port", "HTTP listen port", .range(1...65535))
    var port = 8080

    @Env("trace.ratio", "Fraction of requests traced", .range(0.0...1.0))
    var traceRatio = 0.25

    @Env("debug", "Serve the debug endpoints")
    var debug = false

    @Env("request.timeout", "Upstream request timeout", .range(.seconds(1) ... .seconds(300)))
    var requestTimeout: Duration = .seconds(90)

    @Env("log.level", "Minimum log level")
    var logLevel = FixtureLogLevel.info

    @Env("allowed.origins", "CORS origins allowed to call the API", .items(1...5), .itemLength(1...255), .separator(";"))
    var allowedOrigins: [String]?

    @Env("shards", "Shards this instance owns", .itemRange(0...1023))
    var shards: [Int]?

    @Env("webhook.keys", "Keys that verify webhook signatures", .keyLength(32...256))
    var webhookKeys: KeySet?

    @Env("rate.limits", "Per-client rate limits", .maxLength(1024))
    var rateLimits = FixtureRateLimits(perMinute: 60)

    @Env("old.port", "Port the service used to listen on", .deprecated("Use PORT instead", replacedBy: "PORT"))
    var oldPort: Int?

    @Env("partner.password", "Password of the partner keystore", .secret)
    var partnerPassword: String?

    @FileInput("settings", "Application settings", path: "/etc/app/settings/settings.json", .pathEnv("SETTINGS_FILE"),
               .reload(.watch), .maxSize(65536), .group("general"))
    var settings: ConfigFile<FixtureSettings>

    @FileInput("rules", "Routing rules", path: "/etc/app/rules/rules.yaml")
    var rules: ConfigFile<FixtureSettings>?

    @FileInput("flags", "Feature defaults", path: "/etc/app/flags/flags.toml")
    var flags: ConfigFile<FixtureSettings>?

    @FileInput("serving-tls", "Certificate the service serves HTTPS with", path: "/etc/app/tls", .reload(.watch),
               .dnsNames("app.example.test", "api.example.test"), .keyAlgorithms(.ecdsa, .ed25519),
               .minRemaining(.seconds(720 * 3600)), .requireCA)
    var servingTLS: TLSKeyPair?

    @FileInput("trust", "CAs the service trusts", path: "/etc/app/trust/bundle.pem", .minCertificates(2))
    var trust: CABundle?

    @FileInput("partner", "Client certificate for the partner API", path: "/etc/app/partner/keystore.p12", .format(.pkcs12),
               .passwordVar("PARTNER_PASSWORD"))
    var partner: Keystore?

    @FileInput("licence", "Licence key", path: "/etc/app/licence/licence.key", .length(8...64), .pattern("^[A-Z0-9-]+\\n?$"))
    var licence: TextFile?

    @FileInput("geoip", "GeoIP database", path: "/data/geoip/geoip.mmdb", .maxSize(134_217_728),
               .deprecated("Use geo-db instead", replacedBy: "geo-db"))
    var geoip: BinaryFile?

    @FileInput("geo-db", "City-level location database", path: "/data/geo-db/geo.mmdb")
    var geoDB: BinaryFile?
}

@Suite struct SharedExportTests {
    static let env = ProcessInfo.processInfo.environment
    static let packageRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    /// `DOCUCONF_EXPORT_GOLDEN`, else `export/golden.cue` next to `DOCUCONF_CONFORMANCE`'s `cases.json`, else a
    /// `docuconf-go` checkout next to this repository.
    static var goldenPath: String {
        if let p = env["DOCUCONF_EXPORT_GOLDEN"], !p.isEmpty { return p }
        if let p = env["DOCUCONF_CONFORMANCE"], !p.isEmpty {
            return URL(fileURLWithPath: p).deletingLastPathComponent().appendingPathComponent("export/golden.cue").path
        }
        return packageRoot.deletingLastPathComponent().appendingPathComponent("docuconf-go/conformance/export/golden.cue").path
    }

    /// The docuconf CLI: `DOCUCONF_CLI`, `~/go/bin/docuconf`, or `PATH`.
    static var cli: String? {
        var candidates: [String] = []
        if let c = env["DOCUCONF_CLI"] { candidates.append(c) }
        if let home = env["HOME"] { candidates.append(home + "/go/bin/docuconf") }
        for dir in (env["PATH"] ?? "").split(separator: ":") { candidates.append(dir + "/docuconf") }
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// With `DOCUCONF_REQUIRE_EXPORT=1` (as in CI), a missing CLI or golden file fails the test.
    static var required: Bool { env["DOCUCONF_REQUIRE_EXPORT"] == "1" }

    static func export() throws -> String {
        try Contract.cue(for: FixtureConfig.self, name: "docuconf-fixture", appVersion: "1.0.0")
    }

    @Test func matchesTheSharedGolden() throws {
        let text = try Self.export()
        guard FileManager.default.fileExists(atPath: Self.goldenPath), let cli = Self.cli else {
            let why = "the docuconf CLI or \(Self.goldenPath) is missing (set DOCUCONF_CLI and DOCUCONF_EXPORT_GOLDEN)"
            if Self.required { Issue.record("shared export check required, but \(why)") } else { print("shared export check skipped: \(why)") }
            return
        }
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("docuconf-shared-export-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: dir) }
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let exported = dir.appendingPathComponent("exported.cue")
        try text.write(to: exported, atomically: true, encoding: .utf8)
        if let out = Self.env["DOCUCONF_EXPORT_OUT"], !out.isEmpty {
            try text.write(to: URL(fileURLWithPath: out), atomically: true, encoding: .utf8)
        }
        let (status, output) = try CueVet.run(cli, ["conformance", "export", "--golden", Self.goldenPath, exported.path], in: dir)
        #expect(status == 0, "docuconf conformance export reported differences:\n\(output)")
    }

    @Test func passesCueVet() throws {
        switch try CueVet.vet(Self.export(), package: "docuconf_fixture") {
        case .passed: break
        case .failed(let output): Issue.record("cue vet failed:\n\(output)")
        case .skipped(let why): if CueVet.required { Issue.record("cue vet required but skipped: \(why)") }
        }
    }

    @Test func keySetExportsItsBounds() throws {
        let text = try Self.export()
        for field in ["type: \"keySet\"", "minKeys: 1", "maxKeys: 2", "keyMinLength: 32", "keyMaxLength: 256"] {
            #expect(text.contains(field), "missing \(field)")
        }
    }
}
