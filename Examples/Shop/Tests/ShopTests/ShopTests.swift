import DocuconfCore
import Foundation
import Testing

@testable import Shop

/// The checked-in `contract.json`, which the app reads at start.
private let contractPath = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    .appendingPathComponent("contract.json").path

/// Every case starts from this environment.
private let base = ["DATABASE_URL": "postgres://shop@db:5432/shop"]

/// A webhook signing key of 32 characters or more.
private let signingKey = "whsec-0123456789abcdef0123456789abcdef"

/// Loads `env` on top of the base, as the app does at boot, with a fresh empty `DOCUCONF_FILE_ROOT` that holds the
/// webhook signing key at its contract path when `keyFile` is set.
private func load(_ env: [String: String], keyFile: Bool = false) async throws -> Result<ShopConfig, ConfigurationError> {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("docuconf-shop-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    if keyFile {
        let key = root.appendingPathComponent("etc/shop/webhooks/signing.key")
        try FileManager.default.createDirectory(at: key.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(signingKey.utf8).write(to: key)
    }
    let environment = base.merging(env) { _, new in new }.merging(["DOCUCONF_FILE_ROOT": root.path]) { _, new in new }
    let contract = try ShopConfig.contract(at: contractPath)
    let result: Result<ShopConfig, ConfigurationError>
    do {
        result = .success(try await ShopConfig.load(contract, environment: environment))
    } catch {
        result = .failure(error)
    }
    return result
}

/// What a case expects: the line the app prints, or the one violation it reports.
enum Outcome: Sendable {
    case ok(String)
    /// The input, its code, and text its message contains ("" checks the code only).
    case fails(String, ViolationCode, containing: String)
}

/// One row of the README's test matrix.
struct MatrixCase: Sendable, CustomTestStringConvertible {
    var number: Int
    var env: [String: String]
    var keyFile = false
    var outcome: Outcome

    var testDescription: String { "#\(number)" }
}

private let matrix: [MatrixCase] = [
    MatrixCase(number: 1, env: ["DOCUCONF_ROLE": "web", "ALLOWED_ORIGINS": "https://shop.example"],
               outcome: .ok("shop web: port 8080, origins https://shop.example")),
    // A worker needs no ALLOWED_ORIGINS.
    MatrixCase(number: 2, env: ["DOCUCONF_ROLE": "worker", "QUEUES": "default,mail"],
               outcome: .ok("shop worker: queues default,mail, webhooks off")),
    MatrixCase(number: 3, env: ["DOCUCONF_ROLE": "web"],
               outcome: .fails("ALLOWED_ORIGINS", .missingRequired, containing: "")),
    // Without a role every role-specific input is optional, so the role is the one problem.
    MatrixCase(number: 4, env: ["QUEUES": "default"],
               outcome: .fails("DOCUCONF_ROLE", .missingRequired, containing: "")),
    MatrixCase(number: 5, env: ["DOCUCONF_ROLE": "cron"],
               outcome: .fails("DOCUCONF_ROLE", .notInEnum, containing: "")),
    MatrixCase(number: 6, env: ["DOCUCONF_ROLE": "worker", "QUEUES": "default", "LOG_FORMAT": "json"],
               outcome: .fails("LOG_SCHEMA_URL", .missingRequired, containing: #"is required when LOG_FORMAT is "json""#)),
    MatrixCase(number: 7, env: [
        "DOCUCONF_ROLE": "worker", "QUEUES": "default", "LOG_FORMAT": "json", "LOG_SCHEMA_URL": "https://logs.example/v1.json",
    ], outcome: .ok("shop worker: queues default, webhooks off")),
    MatrixCase(number: 8, env: ["DOCUCONF_ROLE": "worker", "QUEUES": "default", "WEBHOOKS_ENABLED": "true"],
               outcome: .fails("webhook-signing-key", .fileMissing, containing: ", and is required when WEBHOOKS_ENABLED is true")),
    MatrixCase(number: 9, env: ["DOCUCONF_ROLE": "worker", "QUEUES": "default", "WEBHOOKS_ENABLED": "true"], keyFile: true,
               outcome: .ok("shop worker: queues default, webhooks on")),
    // The key file belongs to the worker role.
    MatrixCase(number: 10, env: ["DOCUCONF_ROLE": "web", "ALLOWED_ORIGINS": "https://shop.example", "WEBHOOKS_ENABLED": "true"],
               outcome: .ok("shop web: port 8080, origins https://shop.example")),
    // The otel@1 fragment's variables are checked at boot like any other.
    MatrixCase(number: 11, env: [
        "DOCUCONF_ROLE": "web", "ALLOWED_ORIGINS": "https://shop.example", "OTEL_EXPORTER_OTLP_PROTOCOL": "carrier-pigeon",
    ], outcome: .fails("OTEL_EXPORTER_OTLP_PROTOCOL", .notInEnum, containing: "")),
]

@Test(arguments: matrix)
func matrixCase(_ c: MatrixCase) async throws {
    let result = try await load(c.env, keyFile: c.keyFile)
    switch (result, c.outcome) {
    case (.success(let config), .ok(let line)):
        #expect(config.summary == line)
    case (.failure(let error), .fails(let input, let code, let containing)):
        #expect(error.violations.count == 1, "\(error)")
        let violation = try #require(error.violations.first)
        #expect(violation.input == input, "\(error)")
        #expect(violation.code == code, "\(error)")
        #expect(containing.isEmpty || violation.message.contains(containing), "\(violation.message)")
    case (.success(let config), .fails):
        Issue.record("want a violation, but it loaded \(config)")
    case (.failure(let error), .ok):
        Issue.record("want a valid configuration, but got \(error)")
    }
}

/// The printed queues come from the typed configuration, in the order given.
@Test func typedValues() async throws {
    let worker = try await load(["DOCUCONF_ROLE": "worker", "QUEUES": "mail,default"]).get()
    #expect(worker.role == .worker)
    #expect(worker.queues == ["mail", "default"])
    #expect(worker.allowedOrigins.isEmpty)
    #expect(!worker.webhooksEnabled)
    let web = try await load(["DOCUCONF_ROLE": "web", "ALLOWED_ORIGINS": "https://a.example,https://b.example", "PORT": "9090"]).get()
    #expect(web.role == .web)
    #expect(web.port == 9090)
    #expect(web.allowedOrigins == ["https://a.example", "https://b.example"])
}

/// The contract is read as checked in: its roles and fragment.
@Test func contractDeclaresRolesAndFragment() throws {
    let contract = try ShopConfig.contract(at: contractPath)
    #expect(contract.roles == ["web", "worker"])
    #expect(contract.includes == ["otel@1"])
    #expect(contract.inputRoles["webhook-signing-key"] == ["worker"])
    #expect(contract.conditions["LOG_SCHEMA_URL"] == RequiredIf(variable: "LOG_FORMAT", value: .string("json")))
    #expect(contract.conditions["webhook-signing-key"] == RequiredIf(variable: "WEBHOOKS_ENABLED", value: .bool(true)))
}

/// A bad secret is reported without its value.
@Test func secretsAreNotPrinted() async throws {
    let result = try await load([
        "DOCUCONF_ROLE": "web", "ALLOWED_ORIGINS": "https://shop.example", "DATABASE_URL": "mysql://shop:hunter2@db:3306/shop",
    ])
    guard case .failure(let error) = result else {
        Issue.record("want invalid_scheme for DATABASE_URL")
        return
    }
    #expect(error.violations.map { "\($0.input)/\($0.code.rawValue)" } == ["DATABASE_URL/invalid_scheme"])
    #expect(!"\(error)".contains("hunter2"), "\(error)")
}
