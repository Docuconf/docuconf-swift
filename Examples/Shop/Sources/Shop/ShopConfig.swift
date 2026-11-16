import DocuconfCore
import Foundation

/// The role a shop workload runs as, from `DOCUCONF_ROLE` (SPEC §4.9): one image runs the web server and the worker.
enum Role: String, Sendable {
    case web, worker
}

/// The shop's configuration, typed from the values contract-first mode loads against `contract.json`.
struct ShopConfig: Sendable, Equatable {
    var role: Role
    /// `PORT`, used by the web role. It has its default, 8080, in every role.
    var port: Int
    /// `ALLOWED_ORIGINS`, required in the web role and empty in the worker.
    var allowedOrigins: [String]
    /// `QUEUES`, required in the worker role and empty in the web server.
    var queues: [String]
    /// `WEBHOOKS_ENABLED`, used by the worker role. While it is true, the worker needs the `webhook-signing-key` file.
    var webhooksEnabled: Bool

    /// Reads the contract, exported as JSON. Throws ``DeclarationError`` when it is not a contract the SDK can load.
    static func contract(at path: String) throws -> ContractDocument {
        try ContractDocument(json: Data(contentsOf: URL(fileURLWithPath: path)))
    }

    /// Validates `environment`, and the files it points at (under `DOCUCONF_FILE_ROOT` when it sets it), against
    /// `contract`. Throws ``ConfigurationError`` with every violation, never containing a secret's value.
    static func load(_ contract: ContractDocument, environment: [String: String]) async throws(ConfigurationError) -> ShopConfig {
        let values = try await contract.load(environment: environment)
        return ShopConfig(values)
    }

    /// Like ``load(_:environment:)`` on the process environment, but on a problem it prints every violation at once
    /// to standard error and exits 1. This is the call for `main`.
    static func loadOrExit(contract path: String, environment: [String: String] = ProcessInfo.processInfo.environment) async -> ShopConfig {
        let contract: ContractDocument
        do {
            contract = try Self.contract(at: path)
        } catch {
            exitWithError("shop: cannot read the contract at \(path): \(error)")
        }
        do {
            return try await load(contract, environment: environment)
        } catch {
            exitWithError("\(error)")
        }
    }

    private static func exitWithError(_ text: String) -> Never {
        FileHandle.standardError.write(Data((text + "\n").utf8))
        exit(1)
    }

    /// The typed configuration from loaded values. The contract makes `DOCUCONF_ROLE` a required enum of the roles,
    /// so a successful load always has one.
    init(_ values: ContractValues) {
        func strings(_ name: String) -> [String] {
            if case .stringList(let list)? = values[name] { return list }
            return []
        }
        guard case .enumCase(let name)? = values[ContractDocument.roleVariable], let role = Role(rawValue: name) else {
            preconditionFailure("the contract makes DOCUCONF_ROLE a required enum of web and worker")
        }
        self.role = role
        if case .int(let port)? = values["PORT"] {
            self.port = port
        } else {
            self.port = 8080
        }
        self.allowedOrigins = strings("ALLOWED_ORIGINS")
        self.queues = strings("QUEUES")
        if case .bool(let enabled)? = values["WEBHOOKS_ENABLED"] {
            self.webhooksEnabled = enabled
        } else {
            self.webhooksEnabled = false
        }
    }

    /// The one line the app prints once its configuration is valid.
    var summary: String {
        switch role {
        case .web: "shop web: port \(port), origins \(allowedOrigins.joined(separator: ","))"
        case .worker: "shop worker: queues \(queues.joined(separator: ",")), webhooks \(webhooksEnabled ? "on" : "off")"
        }
    }
}
