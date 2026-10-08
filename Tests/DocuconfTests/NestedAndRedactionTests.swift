import Configuration
import Docuconf
import Foundation
import Testing

// Grouping variables in a nested struct, as Swift developers do.
struct PoolSettings: Sendable {
    @Env("database.pool.size", "Connections in the pool", .range(1...100)) var size = 10
    var limits = PoolLimits()
}

struct PoolLimits: Sendable {
    @Env("database.pool.max.idle", "Idle connections kept open", .range(0...50)) var maxIdle = 2
}

struct NestedConfig: DocuconfConfig {
    @Env("http.port", "HTTP listen port", .range(1...65535)) var port = 8080
    var pool = PoolSettings()
    let name = "orders"  // plain properties are ignored
}

struct OptionalGroupConfig: DocuconfConfig {
    @Env("http.port", "HTTP listen port") var port = 8080
    var pool: PoolSettings? = PoolSettings()
}

struct ArrayGroupConfig: DocuconfConfig {
    var pools = [PoolSettings()]
}

struct EchoToken: Decodable, Sendable, ValidatedConfig {
    var token: String
    // A careless validator that echoes the value.
    func validate() -> [String] { token.contains("hunter2") ? ["token \(token) is revoked"] : [] }
}

struct PrintConfig: DocuconfConfig {
    @Env("http.port", "HTTP listen port") var port = 8080
    @Env("database.url", "Primary database", .secret) var databaseURL: URL
    @Env("api.key", "Partner API key", .secret) var apiKey: String?
    @Env("rate.limit", "Per-client rate limit", .secret) var rateLimit: RateLimit?
    @FileInput("license", "Licence key", path: "/etc/svc/license/license.key", .secret) var license: TextFile?
    @FileInput("token", "Partner token file", path: "/etc/svc/token/token.json", .secret) var token: ConfigFile<EchoToken>?
}

@Suite struct NestedStructTests {
    @Test func nestedVariablesAreDeclaredReadAndExported() async throws {
        let names = try Declaration(NestedConfig.self).vars.map(\.name)
        #expect(Set(names) == ["HTTP_PORT", "DATABASE_POOL_SIZE", "DATABASE_POOL_MAX_IDLE"])

        let c = try await Docuconf.load(NestedConfig.self, environment: ["DATABASE_POOL_SIZE": "20", "DATABASE_POOL_MAX_IDLE": "5"])
        #expect(c.pool.size == 20)
        #expect(c.pool.limits.maxIdle == 5)

        let contract = try Contract.cue(for: NestedConfig.self, name: "nested")
        #expect(contract.contains("DATABASE_POOL_SIZE"))
        #expect(contract.contains("DATABASE_POOL_MAX_IDLE"))
    }

    @Test func nestedVariablesAreValidated() async throws {
        do {
            _ = try await Docuconf.load(NestedConfig.self, environment: ["DATABASE_POOL_SIZE": "0"])
            Issue.record("expected a violation")
        } catch let e as ConfigurationError {
            #expect(e.violations.map(\.description) == [#"DATABASE_POOL_SIZE [out_of_range]: is below min 1 (got "0")"#])
        }
    }

    @Test func inputsWhereTheyCannotBeReadAreADeclarationError() throws {
        for (type, path) in [(OptionalGroupConfig.self as any DocuconfConfig.Type, "pool"), (ArrayGroupConfig.self, "pools")] {
            do {
                _ = try Declaration(type)
                Issue.record("\(type) should be rejected")
            } catch let e as DeclarationError {
                #expect(e.problems.count == 1)
                #expect(e.problems[0].hasPrefix("\(path): "))
                #expect(e.problems[0].contains("plain stored structs"))
            }
        }
    }
}

@Suite struct RedactionTests {
    let secretURL = "postgres://u:hunter2@db.internal/app"

    func loaded() async throws -> PrintConfig {
        let box = try Sandbox(["DATABASE_URL": secretURL, "API_KEY": "key-hunter2", "RATE_LIMIT": #"{"rps":1,"burst":2}"#])
        try box.write("/etc/svc/license/license.key", "LICENSE-hunter2")
        try box.write("/etc/svc/token/token.json", #"{"token":"tok-ok"}"#)
        let c = try await box.load(PrintConfig.self)
        // The box is kept alive by nothing else; the values were read already.
        _ = box
        return c
    }

    @Test func printInterpolationAndDebugDescriptionNeverShowSecrets() async throws {
        let c = try await loaded()
        #expect(c.databaseURL.absoluteString == secretURL, "the app still sees the value")
        for text in [String(describing: c), String(reflecting: c), "\(c)"] {
            #expect(!text.contains("hunter2"), "\(text)")
            #expect(text.contains("8080"))
            #expect(text.contains("<redacted>"))
            #expect(!text.contains("VarSpec"), "print shows values, not specs")
            #expect(text.count < 400, "\(text.count) characters: \(text)")
        }
    }

    @Test func dumpNeverShowsSecrets() async throws {
        let c = try await loaded()
        var out = ""
        dump(c, to: &out)
        #expect(!out.contains("hunter2"), "\(out)")
        #expect(!out.contains("tok-ok"), "\(out)")
        #expect(out.contains("<redacted>"))
        #expect(out.contains("8080"))
        #expect(!out.contains("VarSpec"))
        #expect(!out.contains("stored"))
    }

    @Test func mirrorOfAWrapperHidesItsStorage() async throws {
        let c = try await loaded()
        for child in Mirror(reflecting: c).children {
            var out = ""
            dump(child.value, to: &out)
            #expect(!out.contains("hunter2"), "\(child.label ?? ""): \(out)")
        }
    }

    @Test func validatorAndDecodingErrorsOfSecretsNeverShowTheValue() async throws {
        let box = try Sandbox(["DATABASE_URL": secretURL, "RATE_LIMIT": #"{"rps":"hunter2","burst":1}"#])
        try box.write("/etc/svc/token/token.json", #"{"token":"tok-hunter2"}"#)
        let v = await box.violations(PrintConfig.self)
        #expect(Set(v.map(\.input)) == ["RATE_LIMIT", "token"])
        #expect(!v.description.contains("hunter2"), "\(v)")
        #expect(!(box.terminationLog ?? "").contains("hunter2"))
    }
}

