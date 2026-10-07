import Foundation

/// Contract-first mode (SPEC §11.2 item 11): validates an environment against a contract given as JSON
/// (`cue export contract.cue --out json`), with no Swift declaration.
///
/// ```swift
/// let contract = try ContractDocument(json: Data(contentsOf: URL(fileURLWithPath: "contract.json")))
/// let values = try contract.load()   // the process environment; throws ConfigurationError
/// let port = values["PORT"]          // ParsedValue.int(8080)
/// ```
///
/// Every encoding in SPEC §5 is parsed: lists as `csv` (with the contract's `separator`), `json` or `indexed`
/// (`NAME__0`, `NAME__1`, ...), durations as `go`, `iso8601`, `seconds` or `timespan`. The checks are the ones
/// the declaration path runs (``VarSpec/resolve(raw:parse:)`` and ``VarSpec/check(_:)``). A `json` variable must
/// be valid JSON; it is not checked against its JSON Schema. File inputs and overlays in the contract are ignored.
public struct ContractDocument: Sendable {
    /// `metadata.name`.
    public let name: String?
    /// The contract's variables, sorted by name.
    public let vars: [VarSpec]

    /// Reads a contract exported as JSON. Throws ``DeclarationError`` when it is not a contract this SDK can
    /// load: an unknown type, a malformed constraint, a default that breaks its own constraints.
    public init(json: Data) throws {
        let value: JSONValue
        do {
            value = try JSONDecoder().decode(JSONValue.self, from: json)
        } catch {
            throw DeclarationError(problems: ["the contract is not valid JSON"])
        }
        try self.init(contract: value)
    }

    /// Reads a contract already decoded as JSON.
    public init(contract: JSONValue) throws {
        guard case .object = contract else { throw DeclarationError(problems: ["the contract is not a JSON object"]) }
        var problems: [String] = []
        if let kind = contract["kind"], kind != "ConfigContract" { problems.append("kind must be ConfigContract") }
        if let api = contract["apiVersion"], api != "docuconf.dev/v1alpha1" {
            problems.append("apiVersion \(api.jsonText) is not supported; this SDK reads docuconf.dev/v1alpha1")
        }
        if case .string(let n)? = contract["metadata"]?["name"] { name = n } else { name = nil }
        var vars: [VarSpec] = []
        switch contract["vars"] {
        case nil, .null?:
            break
        case .object(let members)?:
            for (key, entry) in members.sorted(by: { $0.0 < $1.0 }) {
                vars.append(Self.spec(key, entry))
            }
        default:
            problems.append("vars must be an object")
        }
        self.vars = vars
        problems += Declaration.validate(vars: vars, files: []).problems
        if !problems.isEmpty { throw DeclarationError(problems: problems) }
    }

    /// Validates the process environment against the contract.
    public func load() throws(ConfigurationError) -> ContractValues {
        try load(environment: ProcessInfo.processInfo.environment)
    }

    /// Validates `environment`, the whole environment, against the contract. Variables the contract does not
    /// declare are ignored.
    ///
    /// - Throws: ``ConfigurationError`` with every violation, never containing a secret's value.
    public func load(environment: [String: String]) throws(ConfigurationError) -> ContractValues {
        var values: [String: ParsedValue] = [:]
        var violations: [Violation] = []
        for spec in vars {
            let (raw, parsed) = spec.parse(environment: environment)
            switch spec.resolve(raw: raw, parse: { parsed }) {
            case .success(let value?): values[spec.name] = value
            case .success(nil): if let d = spec.defaultParsed { values[spec.name] = d }
            case .failure(let e): violations += e.violations
            }
        }
        if !violations.isEmpty { throw ConfigurationError(violations: violations) }
        return ContractValues(names: vars.map(\.name), values: values)
    }

    // MARK: - Reading a contract entry

    static func spec(_ key: String, _ entry: JSONValue) -> VarSpec {
        var problems: [String] = []
        func string(_ field: String) -> String? {
            switch entry[field] {
            case nil, .null?: return nil
            case .string(let s)?: return s
            default: problems.append("\(key): \(field) must be a string"); return nil
            }
        }
        func bool(_ field: String) -> Bool {
            switch entry[field] {
            case nil, .null?: return false
            case .bool(let b)?: return b
            default: problems.append("\(key): \(field) must be a boolean"); return false
            }
        }
        func int(_ field: String) -> Int? {
            switch entry[field] {
            case nil, .null?: return nil
            case .int(let i)?: return i
            default: problems.append("\(key): \(field) must be an integer"); return nil
            }
        }
        func strings(_ field: String) -> [String]? {
            switch entry[field] {
            case nil, .null?: return nil
            case .array(let a)?:
                let s = a.compactMap { if case .string(let s) = $0 { s } else { nil } }
                if s.count != a.count { problems.append("\(key): \(field) must be a list of strings") }
                return s
            default: problems.append("\(key): \(field) must be a list of strings"); return nil
            }
        }
        func duration(_ field: String) -> Duration? {
            guard let s = string(field) else { return nil }
            guard let d = GoDuration.parse(s) else { problems.append("\(key): \(field) \(s) is not a Go duration"); return nil }
            return d
        }
        func number(_ field: String, float: Bool) -> Number? {
            switch entry[field] {
            case nil, .null?: return nil
            case .int(let i)?: return float ? .double(Double(i)) : .int(i)
            case .double(let d)? where float: return .double(d)
            default: problems.append("\(key): \(field) must be \(float ? "a number" : "an integer")"); return nil
            }
        }

        let typeName = string("type") ?? ""
        let type = VarType(rawValue: typeName)
        if type == nil { problems.append("\(key): unknown type \"\(typeName)\"") }
        let name = string("name") ?? key
        if name != key { problems.append("\(key): name \(name) does not match its key") }
        var spec = VarSpec(name: key, key: string("configKey") ?? key, type: type ?? .string, description: string("description") ?? "")
        spec.required = bool("required")
        spec.secret = bool("secret")
        spec.group = string("group")
        spec.examples = strings("examples")
        if case .string(let m)? = entry["deprecated"]?["message"] {
            spec.deprecated = Deprecation(message: m, replacedBy: entry["deprecated"]?["replacedBy"].flatMap { if case .string(let r) = $0 { r } else { nil } })
        }
        switch spec.type {
        case .string:
            spec.minLength = int("minLength")
            spec.maxLength = int("maxLength")
            spec.pattern = string("pattern")
        case .int, .float:
            spec.min = number("min", float: spec.type == .float)
            spec.max = number("max", float: spec.type == .float)
        case .duration:
            spec.minDuration = duration("min")
            spec.maxDuration = duration("max")
            if let e = string("encoding") {
                if let enc = DurationEncoding(rawValue: e) { spec.durationWire = enc } else { problems.append("\(key): unknown duration encoding \(e)") }
            } else {
                spec.durationWire = .go
            }
        case .url:
            spec.schemes = strings("schemes")
        case .enum:
            spec.values = strings("values")
        case .list:
            let items = string("items") ?? "string"
            switch items {
            case "string": spec.items = .string
            case "int": spec.items = .int
            default: problems.append("\(key): list items must be string or int")
            }
            if let e = string("encoding") {
                if let enc = ListEncoding(rawValue: e) { spec.listWire = enc } else { problems.append("\(key): unknown list encoding \(e)") }
            }
            if let sep = string("separator") {
                if sep.isEmpty { problems.append("\(key): separator cannot be empty") }
                spec.separator = sep
            }
            spec.minItems = int("minItems")
            spec.maxItems = int("maxItems")
            spec.itemMin = int("itemMin")
            spec.itemMax = int("itemMax")
        case .json:
            spec.schema = entry["schema"]
        case .bool:
            break
        }
        if let d = entry["default"], d != .null {
            spec.defaultValue = d
            if let parsed = defaultValue(d, spec) {
                spec.defaultParsed = parsed
            } else {
                problems.append("\(key): default \(d.jsonText) is not a \(spec.type.rawValue)")
            }
        }
        spec.problems = problems
        return spec
    }

    /// A contract default (typed JSON, durations in Go syntax) as a parsed value.
    static func defaultValue(_ d: JSONValue, _ spec: VarSpec) -> ParsedValue? {
        switch (spec.type, d) {
        case (.string, .string(let s)): return .string(s)
        case (.url, .string(let s)): return .url(s)
        case (.enum, .string(let s)): return .enumCase(s)
        case (.int, .int(let i)): return .int(i)
        case (.float, .int(let i)): return .double(Double(i))
        case (.float, .double(let x)): return .double(x)
        case (.bool, .bool(let b)): return .bool(b)
        case (.duration, .string(let s)): return GoDuration.parse(s).map(ParsedValue.duration)
        case (.json, _): return .json(d.jsonText)
        case (.list, .array(let a)):
            if spec.items == .int {
                let ints = a.compactMap { if case .int(let i) = $0 { i } else { nil } }
                return ints.count == a.count ? .intList(ints) : nil
            }
            let strings = a.compactMap { if case .string(let s) = $0 { s } else { nil } }
            return strings.count == a.count ? .stringList(strings) : nil
        default: return nil
        }
    }
}

/// The typed values a ``ContractDocument`` loaded: set values, and defaults for unset ones.
public struct ContractValues: Sendable {
    /// Every variable the contract declares, sorted.
    public let names: [String]
    /// Values by variable name. An optional variable that is unset and has no default is absent.
    public let values: [String: ParsedValue]

    public subscript(name: String) -> ParsedValue? { values[name] }

    /// Every declared variable as JSON (SPEC §12): `null` when absent, durations in canonical Go form.
    public var json: JSONValue {
        .object(names.map { ($0, values[$0]?.jsonValue ?? .null) })
    }
}
