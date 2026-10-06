import Configuration
import Docuconf
import Foundation
import Testing

enum LogLevel: String, ConfigEnum {
    case debug, info, warn, error
}

struct RateLimit: JSONConfigValue, Equatable {
    var rps: Int
    var burst: Int
}

struct ServiceConfig: DocuconfConfig {
    @Env("http.port", "HTTP listen port", .range(1...65535)) var port = 8080
    @Env("database.url", "Primary database", .secret, .schemes("postgres", "postgresql")) var databaseURL: URL
    @Env("log.level", "Minimum log level") var logLevel = LogLevel.info
    @Env("request.timeout", "Upstream request timeout", .max(.seconds(300))) var timeout: Duration = .seconds(30)
    @Env("allowed.hosts", "Hosts allowed to call us", .items(1...3)) var allowedHosts = ["localhost"]
    @Env("extra.ports", "Extra ports to listen on") var extraPorts: [Int]?
    @Env("sampling.ratio", "Sampling ratio", .range(0.0...1.0)) var ratio = 0.5
    @Env("debug", "Verbose request logging") var debug = false
    @Env("api.token", "Partner API token", .secret, .minLength(8)) var apiToken: String
    @Env("rate.limit", "Per-client rate limit") var rateLimit = RateLimit(rps: 10, burst: 20)
    @Env("otel.endpoint", "OTLP endpoint") var otelEndpoint: URL?
    @Env("region", "Cloud region", .pattern("^[a-z]+-[a-z]+-[0-9]$")) var region = "eu-west-1"
    @Env("old.timeout", "Old timeout", .deprecated("Use REQUEST_TIMEOUT", replacedBy: "REQUEST_TIMEOUT")) var oldTimeout: Duration?
}

let validEnv = [
    "DATABASE_URL": "postgres://app:s3cr3t-pw@db:5432/app",
    "API_TOKEN": "tok-123456789",
]

@Suite struct VarTests {
    @Test func loadsTypedValuesAndDefaults() async throws {
        let box = try Sandbox(validEnv.merging([
            "HTTP_PORT": "9090", "LOG_LEVEL": "warn", "REQUEST_TIMEOUT": "1.5", "ALLOWED_HOSTS": "a.example,b.example",
            "EXTRA_PORTS": "81,82", "DEBUG": "TRUE", "RATE_LIMIT": #"{"rps":5,"burst":7}"#,
        ]) { $1 })
        let c = try await box.load(ServiceConfig.self)
        #expect(c.port == 9090)
        #expect(c.databaseURL.scheme == "postgres")
        #expect(c.logLevel == .warn)
        #expect(c.timeout == .milliseconds(1500))
        #expect(c.allowedHosts == ["a.example", "b.example"])
        #expect(c.extraPorts == [81, 82])
        #expect(c.ratio == 0.5)
        #expect(c.debug == true)
        #expect(c.apiToken == "tok-123456789")
        #expect(c.rateLimit == RateLimit(rps: 5, burst: 7))
        #expect(c.otelEndpoint == nil)
        #expect(c.region == "eu-west-1")
        #expect(box.terminationLog == nil)
    }

    @Test func badInt() async throws {
        let box = try Sandbox(validEnv.merging(["HTTP_PORT": "80a"]) { $1 })
        let v = await box.violations(ServiceConfig.self)
        #expect(v.map(\.code) == [.invalidType])
        #expect(v[0].input == "HTTP_PORT")
        #expect(v[0].message.contains("\"80a\""))
    }

    @Test func missingRequired() async throws {
        let box = try Sandbox(["API_TOKEN": "tok-123456789"])
        let v = await box.violations(ServiceConfig.self)
        #expect(v == [Violation(.missingRequired, "DATABASE_URL", "is required but not set")])
    }

    @Test func emptyIsUnsetForNonStrings() async throws {
        let box = try Sandbox(validEnv.merging(["HTTP_PORT": "", "DEBUG": "", "REGION": ""]) { $1 })
        let v = await box.violations(ServiceConfig.self)
        // HTTP_PORT and DEBUG take their defaults; REGION is a string, so "" is a value and fails the pattern.
        #expect(v.map(\.input) == ["REGION"])
        #expect(v.map(\.code) == [.patternMismatch])
        let box2 = try Sandbox(validEnv.merging(["DATABASE_URL": ""]) { $1 })
        #expect(await box2.violations(ServiceConfig.self).map(\.code) == [.missingRequired])
    }

    @Test func constraintCodes() async throws {
        let box = try Sandbox([
            "DATABASE_URL": "mysql://u:p@db/x", "API_TOKEN": "short", "HTTP_PORT": "70000", "LOG_LEVEL": "verbose",
            "REQUEST_TIMEOUT": "600", "ALLOWED_HOSTS": "a,b,c,d", "SAMPLING_RATIO": "nan", "REGION": "EU",
            "RATE_LIMIT": #"{"rps":"many"}"#, "OTEL_ENDPOINT": "not a url", "DEBUG": "maybe",
        ])
        let v = await box.violations(ServiceConfig.self)
        let codes = Dictionary(v.map { ($0.input, $0.code) }, uniquingKeysWith: { a, _ in a })
        #expect(codes == [
            "HTTP_PORT": .outOfRange, "DATABASE_URL": .invalidScheme, "LOG_LEVEL": .notInEnum,
            "REQUEST_TIMEOUT": .outOfRange, "ALLOWED_HOSTS": .tooManyItems, "SAMPLING_RATIO": .invalidType,
            "DEBUG": .invalidType, "API_TOKEN": .outOfRange, "RATE_LIMIT": .schemaMismatch,
            "OTEL_ENDPOINT": .invalidType, "REGION": .patternMismatch,
        ])
        #expect(v.count == 11, "every violation is reported together")
    }

    @Test func secretsAreNeverPrinted() async throws {
        let box = try Sandbox(["DATABASE_URL": "mysql://admin:Sup3rS3cret@db/x", "API_TOKEN": "Sup3r"])
        do {
            _ = try await box.load(ServiceConfig.self)
            Issue.record("expected a ConfigurationError")
        } catch let e as ConfigurationError {
            let text = e.description
            #expect(e.violations.map(\.code) == [.invalidScheme, .outOfRange])
            #expect(!text.contains("Sup3r"))
            #expect(!text.contains("mysql"))
            #expect(!(box.terminationLog ?? "").contains("Sup3r"))
        }
    }

    @Test(arguments: [
        ("vault:secret/data/app/db#url", "vault:"),
        ("op://Production/app-db/url", "op://"),
        ("ref+awssecrets://app/db#/url", "ref+"),
    ])
    func unresolvedInjectorReference(reference: String, scheme: String) async throws {
        // The injector (vault-env, `op run`, vals) did not run, so the secret still holds its reference.
        let box = try Sandbox(validEnv.merging(["DATABASE_URL": reference]) { $1 })
        let v = await box.violations(ServiceConfig.self)
        #expect(v == [Violation(.invalidType, "DATABASE_URL",
                                "holds an unresolved \(scheme) reference; the injector that should resolve it did not run")])
        let path = String(reference.dropFirst(scheme.count))
        #expect(!v[0].message.contains(path))
        let log = try #require(box.terminationLog)
        #expect(log.contains("DATABASE_URL [invalid_type]: holds an unresolved \(scheme) reference"))
        #expect(!log.contains(path))
    }

    @Test func injectorReferencesAreOnlyCheckedOnSecrets() async throws {
        // A non-secret is checked by its own constraints; a string may legitimately start with "vault:".
        let box = try Sandbox(validEnv.merging(["REGION": "vault:eu-west-1"]) { $1 })
        #expect(await box.violations(ServiceConfig.self).map(\.code) == [.patternMismatch])
        struct Notes: DocuconfConfig {
            @Env("motd", "Message of the day") var motd = ""
        }
        let c = try await Sandbox(["MOTD": "vault: closed today"]).load(Notes.self)
        #expect(c.motd == "vault: closed today")
    }

    @Test func secretNewlineWarning() async throws {
        let box = try Sandbox(validEnv.merging(["API_TOKEN": "tok-123456789\n"]) { $1 })
        _ = try await box.load(ServiceConfig.self)
        #expect(box.warnings.contains { $0.contains("API_TOKEN ends with a newline") && !$0.contains("tok-") })
    }

    @Test func deprecatedWarning() async throws {
        let box = try Sandbox(validEnv.merging(["OLD_TIMEOUT": "5"]) { $1 })
        let c = try await box.load(ServiceConfig.self)
        #expect(c.oldTimeout == .seconds(5))
        #expect(box.warnings == ["OLD_TIMEOUT is deprecated: Use REQUEST_TIMEOUT Use REQUEST_TIMEOUT instead."])
    }

    @Test func terminationLog() async throws {
        let box = try Sandbox(["HTTP_PORT": "x"])
        let v = await box.violations(ServiceConfig.self)
        #expect(v.count == 3)
        let log = try #require(box.terminationLog)
        #expect(log.hasPrefix("docuconf: 3 configuration problems:"))
        #expect(log.contains("HTTP_PORT [invalid_type]"))
        #expect(log.contains("DATABASE_URL [missing_required]"))
    }

    @Test func readsThroughAnyConfigReader() async throws {
        // Values come from whatever providers the app composes; here an in-memory provider with typed values.
        let reader = ConfigReader(providers: [
            InMemoryProvider(values: ["http.port": 7070, "database.url": "postgresql://db/x", "api.token": .init(.string("tok-123456789"), isSecret: true)]),
        ])
        let c = try await Docuconf.load(ServiceConfig.self, from: reader, options: LoadOptions(environment: [:]))
        #expect(c.port == 7070)
        #expect(c.databaseURL.absoluteString == "postgresql://db/x")
    }

    @Test func envNamesMatchTheProvider() throws {
        // The contract's variable names must be exactly what EnvironmentVariablesProvider reads for each key.
        let declaration = try Declaration(ServiceConfig.self)
        for v in declaration.vars {
            let reader = ConfigReader(provider: EnvironmentVariablesProvider(environmentVariables: [v.name: "probe"]))
            #expect(reader.string(forKey: ConfigKey(v.key)) == "probe", "\(v.key) -> \(v.name)")
        }
    }

    @Test func dotEnvIsOptInAndOverridden() async throws {
        let box = try Sandbox(validEnv.merging(["HTTP_PORT": "9000"]) { $1 })
        let dotenv = box.root.appendingPathComponent(".env")
        try "HTTP_PORT=1111\nLOG_LEVEL=debug\n".write(to: dotenv, atomically: true, encoding: .utf8)
        let c = try await Docuconf.load(ServiceConfig.self, dotEnvPath: dotenv.path, options: box.options())
        #expect(c.port == 9000, "the real environment wins")
        #expect(c.logLevel == .debug, "the .env file fills the rest")
    }

    @Test func instancesAreIndependent() async throws {
        let a = try await Sandbox(validEnv.merging(["HTTP_PORT": "1001"]) { $1 }).load(ServiceConfig.self)
        let b = try await Sandbox(validEnv.merging(["HTTP_PORT": "1002"]) { $1 }).load(ServiceConfig.self)
        #expect(a.port == 1001)
        #expect(b.port == 1002)
    }
}
