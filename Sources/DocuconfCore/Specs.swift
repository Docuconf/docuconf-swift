import Foundation

/// Variable types (SPEC §4.3). The set is closed in v1alpha1.
public enum VarType: String, Sendable, CaseIterable {
    case string, int, float, bool, duration, url, `enum`, list, json
}

/// A numeric bound: `int` bounds stay integers, `float` bounds doubles.
public enum Number: Sendable, Hashable, CustomStringConvertible {
    case int(Int)
    case double(Double)

    public var asDouble: Double {
        switch self {
        case .int(let i): Double(i)
        case .double(let d): d
        }
    }

    public var json: JSONValue {
        switch self {
        case .int(let i): .int(i)
        case .double(let d): .double(d)
        }
    }

    public var description: String {
        switch self {
        case .int(let i): String(i)
        case .double(let d): JSONValue.format(d)
        }
    }
}

/// `deprecated: {message, replacedBy?}`.
public struct Deprecation: Sendable, Hashable {
    public var message: String
    public var replacedBy: String?

    public init(message: String, replacedBy: String? = nil) {
        self.message = message
        self.replacedBy = replacedBy
    }
}

/// Everything the contract says about one environment variable.
public struct VarSpec: Sendable {
    /// The environment variable name, derived from `key`.
    public var name: String
    /// The swift-configuration key the app reads, such as `http.port`.
    public var key: String
    public var type: VarType
    public var description: String
    public var required = false
    public var secret = false
    public var group: String?
    public var examples: [String]?
    public var deprecated: Deprecation?

    // string
    public var minLength: Int?
    public var maxLength: Int?
    public var pattern: String?
    // int, float
    public var min: Number?
    public var max: Number?
    // duration
    public var minDuration: Duration?
    public var maxDuration: Duration?
    // url
    public var schemes: [String]?
    // enum
    public var values: [String]?
    // list
    public var items: VarType?
    public var minItems: Int?
    public var maxItems: Int?
    // json
    public var schema: JSONValue?

    /// The default as contract data, if any.
    public var defaultValue: JSONValue?
    /// The default as a typed value, to check against the constraints at declaration time.
    public var defaultParsed: ParsedValue?

    /// Declaration problems found while building the spec (for example a pattern that is not RE2).
    public var problems: [String] = []

    /// Duration encoding: what the host parses. swift-configuration reads numbers, so a duration is a
    /// number of seconds (SPEC §5), read with `ConfigReader.double(forKey:)`.
    public static let durationEncoding = "seconds"
    /// List encoding: swift-configuration's `EnvironmentVariablesProvider` splits arrays on `,`.
    public static let listEncoding = "csv"

    public init(name: String, key: String, type: VarType, description: String) {
        self.name = name
        self.key = key
        self.type = type
        self.description = description
    }
}

/// File input types (SPEC §4.6).
public enum FileType: String, Sendable {
    case config, tls, caBundle, keystore, text, binary
}

/// `reload` (SPEC §4.6.2).
public enum Reload: String, Sendable {
    /// The app reads the file once; a changed source needs a rollout.
    case restart
    /// The app reloads the file itself. With docuconf, iterate `$input.changes()` to receive new contents.
    case watch
}

/// Formats of a `config` file input.
public enum ConfigFormat: String, Sendable {
    case json, yaml, toml
}

/// Keystore formats.
public enum KeystoreFormat: String, Sendable {
    case pkcs12, jks
}

/// Key algorithms a TLS certificate may use.
public enum KeyAlgorithm: String, Sendable, CaseIterable {
    case rsa = "RSA"
    case ecdsa = "ECDSA"
    case ed25519 = "Ed25519"
}

/// Everything the contract says about one file input.
public struct FileSpec: Sendable {
    public var name: String
    public var type: FileType
    public var description: String
    public var path: String
    public var required = false
    public var secret = false
    public var pathEnv: String?
    public var reload: Reload = .restart
    public var maxSize: Int?
    public var group: String?
    public var deprecated: Deprecation?

    // config
    public var format: ConfigFormat?
    public var schema: JSONValue?
    // tls
    public var dnsNames: [String]?
    public var keyAlgorithms: [KeyAlgorithm]?
    public var minRemaining: Duration?
    public var requireCA = false
    // caBundle
    public var minCertificates: Int?
    // keystore
    public var keystoreFormat: KeystoreFormat?
    public var passwordVar: String?
    // text
    public var pattern: String?
    public var minLength: Int?
    public var maxLength: Int?

    public var problems: [String] = []

    public init(name: String, type: FileType, description: String, path: String) {
        self.name = name
        self.type = type
        self.description = description
        self.path = path
        self.secret = type == .tls || type == .keystore
    }
}
