import Foundation

/// Variable types (SPEC §4.3). The set is closed in v1alpha1.
public enum VarType: String, Sendable, CaseIterable {
    case string, int, float, bool, duration, url, `enum`, list, keySet, json
}

/// How a `duration` value is written in the environment (SPEC §5).
public enum DurationEncoding: String, Sendable, CaseIterable {
    /// `1m30s`
    case go
    /// `PT90S`
    case iso8601
    /// `90`, `1.5`
    case seconds
    /// `00:01:30`, `1.02:03:04.5`
    case timespan
}

/// How a `list` value is written in the environment (SPEC §5).
public enum ListEncoding: String, Sendable, CaseIterable {
    /// `a,b`, joined by the variable's `separator`.
    case csv
    /// `["a","b"]`
    case json
    /// Separate variables `NAME__0`, `NAME__1`, ...
    case indexed
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
    /// CommonMark for generated docs only (SPEC §4.2); never read at runtime.
    public var details: String?
    public var required = false
    public var secret = false
    public var group: String?
    public var examples: [String]?
    public var deprecated: Deprecation?

    // string; maxLength also bounds a url, and a json value's wire string
    /// Lengths count Unicode scalars (code points), never bytes or UTF-16 units.
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
    /// Bounds on each item of an `int` list (`itemMin`, `itemMax`). An item type narrower than 64 bits
    /// (`[Int32]`, `[UInt16]`) sets them to its own range.
    public var itemMin: Int?
    public var itemMax: Int?
    /// Bounds on the length of each item of a `string` list (`itemMinLength`, `itemMaxLength`), in Unicode
    /// scalars, checked after the list is split.
    public var itemMinLength: Int?
    public var itemMaxLength: Int?
    // keySet: the number of keys (`minKeys`, default 1; `maxKeys`, default 2) and the length of each key, in
    // Unicode scalars. A key set travels in a list's encodings (``listWire``, ``separator``).
    public var minKeys: Int?
    public var maxKeys: Int?
    public var keyMinLength: Int?
    public var keyMaxLength: Int?
    // json
    public var schema: JSONValue?

    /// The duration encoding the app parses. Declarations read through swift-configuration always use
    /// ``durationEncoding`` (`seconds`); a contract loaded in contract-first mode may use any.
    public var durationWire: DurationEncoding = .seconds
    /// The list encoding the app parses: ``listEncoding`` (`csv`) for declarations, any in contract-first mode.
    public var listWire: ListEncoding = .csv
    /// The `csv` separator.
    public var separator = ","

    /// The fewest keys a `keySet` holds: `minKeys`, or its default 1.
    public var effectiveMinKeys: Int { minKeys ?? 1 }
    /// The most keys a `keySet` holds: `maxKeys`, or its default 2.
    public var effectiveMaxKeys: Int { maxKeys ?? 2 }

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
    /// CommonMark for generated docs only (SPEC §4.2); never read at runtime.
    public var details: String?
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
