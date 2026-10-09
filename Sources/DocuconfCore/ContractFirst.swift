import Foundation

/// Contract-first mode (SPEC §11.2 item 11): validates an environment, and the files it points at, against a
/// contract given as JSON (`cue export contract.cue --out json`), with no Swift declaration.
///
/// ```swift
/// let contract = try ContractDocument(json: Data(contentsOf: URL(fileURLWithPath: "contract.json")))
/// let values = try await contract.load()   // the process environment; throws ConfigurationError
/// let port = values["PORT"]                // ParsedValue.int(8080)
/// ```
///
/// Every encoding in SPEC §5 is parsed: lists and key sets as `csv` (with the contract's `separator`), `json` or
/// `indexed` (`NAME__0`, `NAME__1`, ...), durations as `go`, `iso8601`, `seconds` or `timespan`. The checks are the
/// ones the declaration path runs (``VarSpec/resolve(raw:parse:)`` and ``VarSpec/check(_:)``). A `json` variable
/// must be valid JSON and match its `schema` (``JSONSchemaValidator``; a schema with a keyword the validator does
/// not support is a ``DeclarationError``), or it is `schema_mismatch`.
///
/// Values are layered as a host with config files layers them (SPEC §4.4, §4.7): a variable's `default`, then the
/// selected profile's default, then a config-file overlay, then the environment. File inputs (SPEC §4.6) and
/// overlays are read under `DOCUCONF_FILE_ROOT` when the environment sets it. JSON and TOML files need nothing
/// more; YAML files and the certificate checks (`tls`, `caBundle`, `keystore`) need the server SDK's
/// `DocuconfFileSupport`, passed as `support`.
public struct ContractDocument: Sendable {
    /// `metadata.name`.
    public let name: String?
    /// The contract's variables, sorted by name.
    public let vars: [VarSpec]
    /// The contract's file inputs, sorted by name.
    public let files: [FileSpec]
    /// `profiles`, if the contract has them.
    public let profiles: ContractProfiles?
    /// The contract's config-file overlays, sorted by name.
    public let overlays: [ConfigOverlay]
    /// Each variable's `configKey`, where the contract gives one: where an overlay holds its value.
    public let configKeys: [String: String]

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
        var configKeys: [String: String] = [:]
        switch contract["vars"] {
        case nil, .null?:
            break
        case .object(let members)?:
            for (key, entry) in members.sorted(by: { $0.0 < $1.0 }) {
                vars.append(Self.spec(key, entry))
                if case .string(let k)? = entry["configKey"] { configKeys[key] = k }
            }
        default:
            problems.append("vars must be an object")
        }
        var files: [FileSpec] = []
        switch contract["files"] {
        case nil, .null?:
            break
        case .object(let members)?:
            for (key, entry) in members.sorted(by: { $0.0 < $1.0 }) { files.append(Self.fileSpec(key, entry)) }
        default:
            problems.append("files must be an object")
        }
        var overlays: [ConfigOverlay] = []
        switch contract["overlays"] {
        case nil, .null?:
            break
        case .object(let members)?:
            for (key, entry) in members.sorted(by: { $0.0 < $1.0 }) {
                let (overlay, why) = Self.overlay(key, entry)
                overlays.append(overlay)
                problems += why
            }
        default:
            problems.append("overlays must be an object")
        }
        var profiles: ContractProfiles?
        if let p = contract["profiles"], p != .null {
            let (read, why) = Self.profiles(p, vars: &vars)
            profiles = read
            problems += why
        }
        self.vars = vars
        self.files = files
        self.overlays = overlays
        self.profiles = profiles
        self.configKeys = configKeys
        problems += Declaration.validate(vars: vars, files: files, overlays: overlays, contractFirst: true).problems
        if !problems.isEmpty { throw DeclarationError(problems: problems) }
    }

    /// Validates the process environment, and the files it points at, against the contract.
    public func load(support: any ContractFileSupport = FoundationFileSupport(), warn: @Sendable (String) -> Void = { _ in }) async throws(ConfigurationError) -> ContractValues {
        try await load(environment: ProcessInfo.processInfo.environment, support: support, warn: warn)
    }

    /// Validates `environment`, the whole environment, against the contract. Variables the contract does not
    /// declare are ignored. File inputs and overlays are read at their paths, under `DOCUCONF_FILE_ROOT` when
    /// `environment` sets it.
    ///
    /// - Parameters:
    ///   - support: Parses YAML files and checks certificates and keystores: the server SDK's
    ///     `DocuconfFileSupport`. The default, ``FoundationFileSupport``, reads JSON and TOML only.
    ///   - warn: Receives warnings: a deprecated input that is set (naming it and its message, never its value), a
    ///     variable set both in the environment and in an overlay.
    /// - Throws: ``ConfigurationError`` with every violation, never containing a secret's value.
    public func load(
        environment env: [String: String], support: any ContractFileSupport = FoundationFileSupport(),
        warn: @Sendable (String) -> Void = { _ in }
    ) async throws(ConfigurationError) -> ContractValues {
        var values: [String: ParsedValue] = [:]
        var violations: [Violation] = []
        let root = env["DOCUCONF_FILE_ROOT"].flatMap { $0.isEmpty ? nil : $0 }

        // The layers under the environment: the selected profile's defaults, then the overlays.
        var profileLayer: [String: ParsedValue] = [:]
        if let profiles {
            profileLayer = profiles.defaults[profiles.selected(vars: vars, environment: env)] ?? [:]
        }
        let (overlayLayer, overlayViolations) = readOverlays(root: root, support: support, warn: warn)
        violations += overlayViolations

        for spec in vars {
            let (raw, parsed) = spec.parse(environment: env)
            let overlay = overlayLayer[spec.name]
            if parsed != nil {
                if let overlay, case .value(_, let source) = overlay {
                    warn("\(spec.name) is set in the environment and in overlay \(source); the environment wins")
                }
                if let d = spec.deprecated { warn(Self.deprecationWarning(spec.name, d)) }
            } else if let overlay {
                switch overlay {
                case .bad:
                    continue
                case .value(let wire, let source):
                    let fromOverlay: Result<ParsedValue, Violation>?
                    switch wire {
                    case .raw(let text): fromOverlay = spec.parse(wire: text)
                    case .items(let items): fromOverlay = .some(spec.parseItems(items, raw: items.joined(separator: ",")))
                    }
                    if let fromOverlay {
                        if let d = spec.deprecated { warn(Self.deprecationWarning(spec.name, d) + " (set in overlay \(source))") }
                        switch spec.resolve(raw: nil, parse: { fromOverlay }) {
                        case .success(let value?):
                            if let v = Self.schemaViolation(spec, value) { violations.append(v) } else { values[spec.name] = value }
                        case .success(nil): break
                        case .failure(let e): violations += e.violations
                        }
                        continue
                    }
                }
            }
            if parsed == nil, let p = profileLayer[spec.name] {
                values[spec.name] = p
                continue
            }
            switch spec.resolve(raw: raw, parse: { parsed }) {
            case .success(let value?):
                if let v = Self.schemaViolation(spec, value) { violations.append(v) } else { values[spec.name] = value }
            case .success(nil): if let d = spec.defaultParsed { values[spec.name] = d }
            case .failure(let e): violations += e.violations
            }
        }

        var fileValues: [String: ContractFileValue] = [:]
        for file in files {
            switch await loadFile(file, environment: env, root: root, support: support, warn: warn) {
            case .success(let value?): fileValues[file.name] = value
            case .success(nil): break
            case .failure(let v): violations += v.violations
            }
        }

        if !violations.isEmpty { throw ConfigurationError(violations: violations) }
        return ContractValues(names: vars.map(\.name), values: values, fileNames: files.map(\.name), files: fileValues)
    }

    static func deprecationWarning(_ name: String, _ d: Deprecation) -> String {
        "\(name) is deprecated: \(d.message)" + (d.replacedBy.map { " Use \($0) instead." } ?? "")
    }

    // MARK: - Overlays

    /// A variable's value as an overlay gives it: the wire string (or list items) it stands for, or a value that
    /// was already reported.
    enum OverlayEntry {
        enum Wire {
            case raw(String)
            case items([String])
        }
        case value(Wire, source: String)
        case bad
    }

    /// Reads every overlay (SPEC §4.7), returning each variable's value from the first overlay that sets it.
    func readOverlays(root: String?, support: any ContractFileSupport, warn: (String) -> Void) -> ([String: OverlayEntry], [Violation]) {
        var entries: [String: OverlayEntry] = [:]
        var violations: [Violation] = []
        for overlay in overlays {
            let path = Self.rooted(overlay.path, root)
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) else { continue }  // optional
            if isDirectory.boolValue {
                violations.append(Violation(.fileUnreadable, overlay.name, "overlay \(path) is a directory, not a file"))
                continue
            }
            guard FileManager.default.isReadableFile(atPath: path), let data = FileManager.default.contents(atPath: path) else {
                violations.append(Violation(.fileUnreadable, overlay.name, "overlay \(path) is not readable by this process"))
                continue
            }
            let doc: JSONValue
            do {
                doc = try support.parse(data, format: overlay.format)
            } catch {
                // Overlays hold no secrets, so the parser's position is safe to show.
                violations.append(Violation(.fileMalformed, overlay.name, "overlay \(path) is not valid \(overlay.format.rawValue): \(Self.describe(error))"))
                continue
            }
            guard case .object = doc else {
                violations.append(Violation(.fileMalformed, overlay.name, "overlay \(path) does not hold an object at its top level"))
                continue
            }
            for spec in vars {
                guard let configKey = configKeys[spec.name], spec.name != profiles?.selector else { continue }
                var value: JSONValue? = doc
                for part in configKey.components(separatedBy: overlay.keySeparator) { value = value?[part] }
                guard let value, value != .null else { continue }  // null is unset
                if entries[spec.name] != nil {
                    warn("\(spec.name) is set in more than one overlay; the first, in name order, wins")
                    continue
                }
                if spec.secret {
                    violations.append(Violation(.invalidType, spec.name,
                        "is secret, but overlay \(overlay.name) sets it at \(configKey); supply secrets through the environment"))
                    entries[spec.name] = .bad
                    continue
                }
                switch Self.overlayWire(spec, value) {
                case .success(let wire): entries[spec.name] = .value(wire, source: overlay.name)
                case .failure(let why):
                    violations.append(Violation(.invalidType, spec.name, "overlay \(overlay.name), at \(configKey): \(why)"))
                    entries[spec.name] = .bad
                }
            }
        }
        return (entries, violations)
    }

    struct WireProblem: Error { var message: String }

    /// Converts an overlay's native value to the wire string it stands for (SPEC §4.7): a string as it is, a
    /// boolean as `true` or `false`, an integral number as a base-10 integer, any other number in shortest
    /// round-trip decimal, a list item by item, and a `json` variable's value as compact JSON.
    static func overlayWire(_ spec: VarSpec, _ value: JSONValue) -> Result<OverlayEntry.Wire, WireProblem> {
        switch spec.type {
        case .json:
            return .success(.raw(value.jsonText))
        case .list, .keySet:
            guard case .array(let a) = value else { return .failure(WireProblem(message: "is \(kind(value)), not a list")) }
            var items: [String] = []
            for (i, x) in a.enumerated() {
                guard let s = scalarText(x) else { return .failure(WireProblem(message: "item \(i) is \(kind(x)), not a scalar")) }
                items.append(s)
            }
            return .success(.items(items))
        default:
            guard let s = scalarText(value) else { return .failure(WireProblem(message: "is \(kind(value)), not a scalar")) }
            return .success(.raw(s))
        }
    }

    static func scalarText(_ v: JSONValue) -> String? {
        switch v {
        case .string(let s): return s
        case .bool(let b): return b ? "true" : "false"
        case .int(let i): return String(i)
        case .double(let d):
            if d == d.rounded(), abs(d) < 0x1p63 { return String(Int64(d)) }
            return "\(d)"
        default: return nil
        }
    }

    static func kind(_ v: JSONValue) -> String {
        switch v {
        case .null: "null"
        case .bool: "a boolean"
        case .int, .double: "a number"
        case .string: "a string"
        case .array: "a list"
        case .object: "an object"
        }
    }

    static func describe(_ error: any Error) -> String {
        if let e = error as? MalformedFileError { return e.description }
        if let e = error as? DecodingError, case .dataCorrupted(let ctx) = e {
            return (ctx.underlyingError as NSError?)?.userInfo[NSDebugDescriptionErrorKey] as? String ?? ctx.debugDescription
        }
        return "it does not parse"
    }

    static func rooted(_ path: String, _ root: String?) -> String {
        guard let root, path.hasPrefix("/") else { return path }
        return (root.hasSuffix("/") ? String(root.dropLast()) : root) + path
    }

    // MARK: - File inputs

    /// Loads one file input (SPEC §4.6, §11.2 item 7): `nil` when an optional input is absent.
    func loadFile(
        _ spec: FileSpec, environment env: [String: String], root: String?, support: any ContractFileSupport, warn: (String) -> Void
    ) async -> Result<ContractFileValue?, ConfigurationError> {
        func fail(_ code: ViolationCode, _ message: String) -> Result<ContractFileValue?, ConfigurationError> {
            .failure(ConfigurationError(violations: [Violation(code, spec.name, message)]))
        }
        var path = spec.path
        if let pe = spec.pathEnv, let p = env[pe], !p.isEmpty { path = p }
        path = Self.rooted(path, root)

        var isDirectory: ObjCBool = false
        let present = FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory)
        if !present || isDirectory.boolValue != (spec.type == .tls) {
            guard spec.required else { return .success(nil) }
            let what = spec.type == .tls ? "directory" : "file"
            return fail(.fileMissing, "\(path) \(present ? "is not a \(what)" : "does not exist")")
        }
        if let d = spec.deprecated {
            warn("file input \(spec.name) is deprecated: \(d.message)" + (d.replacedBy.map { " Use \($0) instead." } ?? ""))
        }

        switch spec.type {
        case .tls, .caBundle, .keystore:
            let password = spec.passwordVar.flatMap { env[$0] } ?? ""
            let found = await support.check(spec, at: path, password: password)
            return found.isEmpty ? .success(.present(path: path)) : .failure(ConfigurationError(violations: found))
        case .config, .text, .binary:
            break
        }

        if let maxSize = spec.maxSize, let size = (try? FileManager.default.attributesOfItem(atPath: path))?[.size] as? NSNumber,
            size.intValue > maxSize
        {
            return fail(.fileTooLarge, "\(path) is \(size.intValue) bytes, larger than maxSize \(maxSize)")
        }
        guard FileManager.default.isReadableFile(atPath: path), let data = FileManager.default.contents(atPath: path) else {
            return fail(.fileUnreadable, "\(path) is not readable by this process")
        }
        switch spec.type {
        case .text:
            guard let text = String(data: data, encoding: .utf8) else { return fail(.fileMalformed, "\(path) is not UTF-8 text") }
            let found = spec.checkText(text)
            return found.isEmpty ? .success(.text(text)) : .failure(ConfigurationError(violations: found))
        case .config:
            let format = spec.format ?? .json
            let doc: JSONValue
            do {
                doc = try support.parse(data, format: format)
            } catch {
                return fail(.fileMalformed, "\(path) is not valid \(format.rawValue)" + (spec.secret ? "" : ": \(Self.describe(error))"))
            }
            if let schema = spec.schema {
                let errors = JSONSchemaValidator.validate(doc, against: schema)
                if let first = errors.first {
                    if spec.secret { return fail(.schemaMismatch, "\(path) does not match its schema") }
                    let more = errors.count > 1 ? " (and \(errors.count - 1) more)" : ""
                    return fail(.schemaMismatch, "\(path) does not match its schema: \(first)\(more)")
                }
            }
            return .success(.config(doc))
        default:
            return .success(.present(path: path))
        }
    }

    /// A `json` value that does not match its contract schema. Declared `JSONConfigValue` types are checked by
    /// decoding instead, so this runs in contract-first mode only.
    static func schemaViolation(_ spec: VarSpec, _ value: ParsedValue) -> Violation? {
        guard case .json(let text) = value, let schema = spec.schema,
            let doc = try? JSONDecoder().decode(JSONValue.self, from: Data(text.utf8))
        else { return nil }
        let errors = JSONSchemaValidator.validate(doc, against: schema)
        guard let first = errors.first else { return nil }
        // Paths and property names come from the document itself, so a secret's message names neither.
        if spec.secret { return Violation(.schemaMismatch, spec.name, "does not match its schema") }
        let more = errors.count > 1 ? " (and \(errors.count - 1) more)" : ""
        return Violation(.schemaMismatch, spec.name, "does not match its schema: \(first)\(more)")
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
        // Docs only: checked with the declaration (not blank, at most 4000 characters), never read.
        spec.details = string("details")
        spec.required = bool("required")
        spec.secret = bool("secret")
        spec.group = string("group")
        spec.examples = strings("examples")
        spec.deprecated = deprecation(entry, key, &problems)
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
            spec.maxLength = int("maxLength")
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
            spec.itemMinLength = int("itemMinLength")
            spec.itemMaxLength = int("itemMaxLength")
        case .keySet:
            if let e = string("encoding") {
                if let enc = ListEncoding(rawValue: e) { spec.listWire = enc } else { problems.append("\(key): unknown keySet encoding \(e)") }
            }
            if let sep = string("separator") {
                if sep.isEmpty { problems.append("\(key): separator cannot be empty") }
                spec.separator = sep
            }
            spec.minKeys = int("minKeys")
            spec.maxKeys = int("maxKeys")
            spec.keyMinLength = int("keyMinLength")
            spec.keyMaxLength = int("keyMaxLength")
        case .json:
            spec.schema = entry["schema"]
            if let schema = spec.schema, schema != .null {
                problems += JSONSchemaValidator.problems(in: schema).map { "\(key): schema \($0)" }
            } else {
                spec.schema = nil
            }
            spec.maxLength = int("maxLength")
        case .bool:
            break
        }
        if let d = entry["default"], d != .null {
            spec.defaultValue = d
            if let parsed = defaultValue(d, spec) {
                spec.defaultParsed = parsed
                if let v = schemaViolation(spec, parsed) { problems.append("\(key): default \(v.message)") }
            } else {
                problems.append("\(key): default \(d.jsonText) is not a \(spec.type.rawValue)")
            }
        }
        spec.problems = problems
        return spec
    }

    /// A file input's contract entry.
    static func fileSpec(_ key: String, _ entry: JSONValue) -> FileSpec {
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
        let typeName = string("type") ?? ""
        let type = FileType(rawValue: typeName)
        if type == nil { problems.append("\(key): unknown file type \"\(typeName)\"") }
        var spec = FileSpec(name: key, type: type ?? .binary, description: string("description") ?? "", path: string("path") ?? "")
        spec.details = string("details")
        spec.required = bool("required")
        spec.secret = bool("secret") || spec.type == .tls || spec.type == .keystore
        spec.pathEnv = string("pathEnv")
        if let r = string("reload") {
            if let reload = Reload(rawValue: r) { spec.reload = reload } else { problems.append("\(key): unknown reload \(r)") }
        }
        spec.maxSize = int("maxSize")
        spec.group = string("group")
        spec.deprecated = deprecation(entry, key, &problems)
        switch spec.type {
        case .config:
            if let f = string("format") {
                if let format = ConfigFormat(rawValue: f) { spec.format = format } else { problems.append("\(key): unknown config format \(f)") }
            } else {
                problems.append("\(key): a config file needs a format")
            }
            if let schema = entry["schema"], schema != .null {
                spec.schema = schema
                problems += JSONSchemaValidator.problems(in: schema).map { "\(key): schema \($0)" }
            }
        case .tls:
            spec.dnsNames = strings("dnsNames")
            if let algorithms = strings("keyAlgorithms") {
                spec.keyAlgorithms = algorithms.compactMap { a in
                    guard let k = KeyAlgorithm(rawValue: a) else { problems.append("\(key): unknown key algorithm \(a)"); return nil }
                    return k
                }
            }
            if let m = string("minRemaining") {
                if let d = GoDuration.parse(m) { spec.minRemaining = d } else { problems.append("\(key): minRemaining \(m) is not a Go duration") }
            }
            spec.requireCA = bool("requireCA")
        case .caBundle:
            spec.minCertificates = int("minCertificates")
        case .keystore:
            if let f = string("format") {
                if let format = KeystoreFormat(rawValue: f) { spec.keystoreFormat = format } else { problems.append("\(key): unknown keystore format \(f)") }
            } else {
                spec.keystoreFormat = .pkcs12
            }
            spec.passwordVar = string("passwordVar")
        case .text:
            spec.pattern = string("pattern")
            spec.minLength = int("minLength")
            spec.maxLength = int("maxLength")
        case .binary:
            break
        }
        spec.problems = problems
        return spec
    }

    /// `deprecated: {message, replacedBy?}`.
    static func deprecation(_ entry: JSONValue, _ key: String, _ problems: inout [String]) -> Deprecation? {
        guard let d = entry["deprecated"], d != .null else { return nil }
        guard case .string(let m)? = d["message"] else {
            problems.append("\(key): deprecated needs a message")
            return nil
        }
        var replacedBy: String?
        switch d["replacedBy"] {
        case nil, .null?: break
        case .string(let r)?: replacedBy = r
        default: problems.append("\(key): deprecated.replacedBy must be a string")
        }
        return Deprecation(message: m, replacedBy: replacedBy)
    }

    /// An overlay's contract entry (`#Overlay`).
    static func overlay(_ key: String, _ entry: JSONValue) -> (ConfigOverlay, [String]) {
        var problems: [String] = []
        func string(_ field: String) -> String? {
            if case .string(let s)? = entry[field] { return s }
            if let v = entry[field], v != .null { problems.append("overlay \(key): \(field) must be a string") }
            return nil
        }
        let format = string("format").flatMap { f -> ConfigFormat? in
            guard let format = ConfigFormat(rawValue: f) else { problems.append("overlay \(key): unknown format \(f)"); return nil }
            return format
        }
        let reload = string("reload").flatMap { r -> Reload? in
            guard let reload = Reload(rawValue: r) else { problems.append("overlay \(key): unknown reload \(r)"); return nil }
            return reload
        }
        let overlay = ConfigOverlay(key, string("description"), path: string("path") ?? "", format: format,
                                    keySeparator: string("keySeparator") ?? ConfigOverlay.keySeparator, reload: reload ?? .restart)
        return (overlay, problems)
    }

    /// `profiles` (SPEC §4.4). A selector the contract does not declare is added as an optional `string` variable
    /// whose default is `profiles.default`.
    static func profiles(_ p: JSONValue, vars: inout [VarSpec]) -> (ContractProfiles?, [String]) {
        var problems: [String] = []
        guard case .string(let selector)? = p["selector"], case .string(let def)? = p["default"] else {
            return (nil, ["profiles needs a selector and a default"])
        }
        if !vars.contains(where: { $0.name == selector }) {
            var spec = VarSpec(name: selector, key: selector, type: .string, description: "Selects the profile (added by docuconf)")
            spec.defaultValue = .string(def)
            spec.defaultParsed = .string(def)
            vars.append(spec)
            vars.sort { $0.name < $1.name }
        }
        var defaults: [String: [String: ParsedValue]] = [:]
        switch p["defaults"] {
        case nil, .null?:
            break
        case .object(let profiles)?:
            for (profile, entries) in profiles {
                guard case .object(let members) = entries else {
                    problems.append("profiles.defaults.\(profile) must be an object")
                    continue
                }
                var values: [String: ParsedValue] = [:]
                for (name, value) in members {
                    guard let spec = vars.first(where: { $0.name == name }) else {
                        problems.append("profiles.defaults.\(profile): \(name) is not a declared variable")
                        continue
                    }
                    if spec.secret {
                        problems.append("profiles.defaults.\(profile): \(name) is secret, and a secret cannot have a value in a config file")
                        continue
                    }
                    guard let parsed = defaultValue(value, spec) else {
                        problems.append("profiles.defaults.\(profile): \(name) \(value.jsonText) is not a \(spec.type.rawValue)")
                        continue
                    }
                    for v in spec.check(parsed) {
                        problems.append("profiles.defaults.\(profile): \(name) violates its constraints: \(v.message)")
                    }
                    values[name] = parsed
                }
                defaults[profile] = values
            }
        default:
            problems.append("profiles.defaults must be an object")
        }
        return (ContractProfiles(selector: selector, defaultProfile: def, defaults: defaults), problems)
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

/// `profiles` in a contract (SPEC §4.4): the selector variable, the profile in effect when it is unset, and each
/// profile file's values.
public struct ContractProfiles: Sendable {
    public var selector: String
    /// `profiles.default`.
    public var defaultProfile: String
    /// Values by profile name, then variable name.
    public var defaults: [String: [String: ParsedValue]]

    public init(selector: String, defaultProfile: String, defaults: [String: [String: ParsedValue]]) {
        self.selector = selector
        self.defaultProfile = defaultProfile
        self.defaults = defaults
    }

    /// The profile in effect: the selector's value when the environment sets it, read as SPEC §5 reads the
    /// selector's type (an empty string names a profile for a `string` selector), or else `profiles.default`.
    public func selected(vars: [VarSpec], environment env: [String: String]) -> String {
        if let raw = env[selector], raw != "" || vars.first(where: { $0.name == selector })?.type ?? .string == .string {
            return raw
        }
        return defaultProfile
    }
}

/// Parses structured files and checks certificates for contract-first mode. ``FoundationFileSupport`` reads
/// JSON and TOML; the server SDK's `DocuconfFileSupport` adds YAML (Yams) and the `tls`, `caBundle` and `keystore`
/// checks (swift-certificates, swift-crypto).
public protocol ContractFileSupport: Sendable {
    /// Parses a config file or overlay. Throws ``MalformedFileError`` (or any error) when it does not parse.
    func parse(_ data: Data, format: ConfigFormat) throws -> JSONValue
    /// Checks a `tls` key pair (a directory), CA bundle or keystore at `path`; returns every violation.
    func check(_ spec: FileSpec, at path: String, password: String) async -> [Violation]
}

extension ContractFileSupport {
    /// JSON with Foundation, TOML with ``TOML``.
    public func parseJSONOrTOML(_ data: Data, format: ConfigFormat) throws -> JSONValue {
        var data = data
        if data.starts(with: [0xEF, 0xBB, 0xBF]) { data = data.dropFirst(3) }
        switch format {
        case .json: return try JSONDecoder().decode(JSONValue.self, from: data)
        case .toml: return try TOML.parse(data)
        case .yaml: throw MalformedFileError("YAML files need the Docuconf server SDK (DocuconfFileSupport)")
        }
    }
}

/// JSON and TOML, with Foundation only. Certificates and keystores are reported as unreadable: check them with the
/// server SDK's `DocuconfFileSupport`.
public struct FoundationFileSupport: ContractFileSupport {
    public init() {}

    public func parse(_ data: Data, format: ConfigFormat) throws -> JSONValue {
        try parseJSONOrTOML(data, format: format)
    }

    public func check(_ spec: FileSpec, at path: String, password: String) async -> [Violation] {
        [Violation(.fileUnreadable, spec.name, "\(spec.type.rawValue) inputs are checked by the Docuconf server SDK with its TLS trait; pass DocuconfFileSupport()")]
    }
}

/// A file input's value in contract-first mode.
public enum ContractFileValue: Sendable, Hashable {
    /// A `config` file's data.
    case config(JSONValue)
    /// A `text` file's text, untrimmed.
    case text(String)
    /// A `tls`, `caBundle`, `keystore` or `binary` input that passed its checks, at the path it was read from.
    case present(path: String)

    /// As the conformance suite compares it (SPEC §12): a config file's data, a text file's text, otherwise `true`.
    public var jsonValue: JSONValue {
        switch self {
        case .config(let v): v
        case .text(let t): .string(t)
        case .present: true
        }
    }
}

/// The typed values a ``ContractDocument`` loaded: set values, and defaults for unset ones.
public struct ContractValues: Sendable {
    /// Every variable the contract declares, sorted.
    public let names: [String]
    /// Values by variable name. An optional variable that is unset and has no default is absent.
    public let values: [String: ParsedValue]
    /// Every file input the contract declares, sorted.
    public let fileNames: [String]
    /// File inputs by name. An optional input whose file is absent is absent.
    public let files: [String: ContractFileValue]

    public init(names: [String], values: [String: ParsedValue], fileNames: [String] = [], files: [String: ContractFileValue] = [:]) {
        self.names = names
        self.values = values
        self.fileNames = fileNames
        self.files = files
    }

    public subscript(name: String) -> ParsedValue? { values[name] }

    /// Every declared variable and file input as JSON (SPEC §12): `null` when absent, durations in canonical Go form,
    /// a config file as its data, a text file as its text, any other file input as `true`.
    public var json: JSONValue {
        .object(names.map { ($0, values[$0]?.jsonValue ?? .null) } + fileNames.map { ($0, files[$0]?.jsonValue ?? .null) })
    }
}
