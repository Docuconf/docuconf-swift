import Foundation

/// Storage shared by a property wrapper and its copies: the loader fills it in place.
package final class Box<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Value?

    package init(_ value: Value?) { stored = value }

    package var value: Value? {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }
}

/// Type-erased access to a declared variable, for the loader and the exporter.
package protocol AnyEnv: Sendable {
    var spec: VarSpec { get }
    /// Stores a parsed, checked value.
    func store(_ value: ParsedValue) throws
    /// Marks the variable as unset (it keeps its default, or becomes `nil`).
    func storeUnset()
}

/// Declares an environment variable read through swift-configuration, with the metadata docuconf exports
/// to the contract.
///
/// The first argument is the swift-configuration key; the environment variable name is derived from it
/// exactly as `EnvironmentVariablesProvider` does (`http.port` reads `HTTP_PORT`).
///
/// ```swift
/// @Env("http.port", "HTTP listen port", .range(1...65535)) var port = 8080
/// @Env("database.url", "Primary Postgres connection string", .secret, .schemes("postgres")) var databaseURL: URL
/// @Env("log.level", "Minimum log level") var logLevel = LogLevel.info
/// @Env("tracing.endpoint", "OTLP endpoint; tracing is off when unset") var tracingEndpoint: URL?
/// ```
///
/// A non-optional property with no initial value is **required**. An optional one with no initial value is
/// absent (`nil`) when unset.
@propertyWrapper
public struct Env<Value: EnvValue>: AnyEnv {
    public let spec: VarSpec
    let box: Box<Value>

    public var wrappedValue: Value {
        guard let v = box.value else {
            fatalError("docuconf: \(spec.name) is required and was read before Docuconf.load(...) set it")
        }
        return v
    }

    /// The variable's contract entry.
    public var projectedValue: VarSpec { spec }

    /// A variable with a default.
    public init(wrappedValue: Value, _ key: String, _ description: String, _ rules: VarRule<Value.Base>...) {
        var spec = Self.makeSpec(key, description, rules)
        if let d = wrappedValue.base {
            spec.defaultValue = d.contractValue
            spec.defaultParsed = d.parsed
        }
        self.spec = spec
        self.box = Box(wrappedValue)
    }

    /// A variable with no default: required, or `nil` when unset if `Value` is optional.
    public init(_ key: String, _ description: String, _ rules: VarRule<Value.Base>...) {
        var spec = Self.makeSpec(key, description, rules)
        spec.required = !Value.isOptional
        self.spec = spec
        self.box = Box(Value.wrap(nil))
    }

    static func makeSpec(_ key: String, _ description: String, _ rules: [VarRule<Value.Base>]) -> VarSpec {
        var spec = VarSpec(name: EnvName.forKey(key), key: key, type: Value.Base.varType, description: description)
        do {
            try Value.Base.describe(&spec)
        } catch {
            spec.problems.append("\(spec.name): \(error)")
        }
        for rule in rules { rule.apply(&spec) }
        return spec
    }

    package func store(_ value: ParsedValue) throws {
        box.value = Value.wrap(try Value.Base(parsed: value))
    }

    package func storeUnset() {
        if spec.defaultParsed == nil, let absent = Value.wrap(nil) { box.value = absent }
    }
}

/// A constraint or metadata for an ``Env`` variable. Which rules are available depends on the type:
/// `.range` for numbers and durations, `.length` and `.pattern` for strings, `.schemes` for URLs,
/// `.items` for lists.
public struct VarRule<Base>: Sendable {
    let apply: @Sendable (inout VarSpec) -> Void

    public init(_ apply: @escaping @Sendable (inout VarSpec) -> Void) { self.apply = apply }

    /// The value must come from a secret reference. It is never printed, exported or given a default.
    public static var secret: Self { Self { $0.secret = true } }
    /// Free-form grouping for docs (`database`, `http`).
    public static func group(_ name: String) -> Self { Self { $0.group = name } }
    /// Example values, for docs.
    public static func examples(_ values: String...) -> Self { Self { $0.examples = values } }
    /// The variable is deprecated; docuconf warns at boot when it is set.
    public static func deprecated(_ message: String, replacedBy: String? = nil) -> Self {
        Self { $0.deprecated = Deprecation(message: message, replacedBy: replacedBy) }
    }
}

extension VarRule where Base == Int {
    public static func range(_ r: ClosedRange<Int>) -> Self { Self { $0.min = .int(r.lowerBound); $0.max = .int(r.upperBound) } }
    public static func min(_ v: Int) -> Self { Self { $0.min = .int(v) } }
    public static func max(_ v: Int) -> Self { Self { $0.max = .int(v) } }
}

extension VarRule where Base == Double {
    public static func range(_ r: ClosedRange<Double>) -> Self { Self { $0.min = .double(r.lowerBound); $0.max = .double(r.upperBound) } }
    public static func min(_ v: Double) -> Self { Self { $0.min = .double(v) } }
    public static func max(_ v: Double) -> Self { Self { $0.max = .double(v) } }
}

extension VarRule where Base == Duration {
    public static func range(_ r: ClosedRange<Duration>) -> Self { Self { $0.minDuration = r.lowerBound; $0.maxDuration = r.upperBound } }
    public static func min(_ v: Duration) -> Self { Self { $0.minDuration = v } }
    public static func max(_ v: Duration) -> Self { Self { $0.maxDuration = v } }
}

extension VarRule where Base == String {
    /// Length in Unicode scalars, as CUE's `strings.MinRunes` counts.
    public static func length(_ r: ClosedRange<Int>) -> Self { Self { $0.minLength = r.lowerBound; $0.maxLength = r.upperBound } }
    public static func minLength(_ n: Int) -> Self { Self { $0.minLength = n } }
    public static func maxLength(_ n: Int) -> Self { Self { $0.maxLength = n } }
    /// An RE2 pattern, matched anywhere in the value. Anchor it with `^` and `$` to match the whole value.
    public static func pattern(_ p: String) -> Self { Self { $0.pattern = p } }
}

extension VarRule where Base == URL {
    public static func schemes(_ s: String...) -> Self { Self { $0.schemes = s } }
}

extension VarRule where Base: EnvBaseValue & RangeReplaceableCollection, Base.Element: ListItem {
    public static func items(_ r: ClosedRange<Int>) -> Self { Self { $0.minItems = r.lowerBound; $0.maxItems = r.upperBound } }
    public static func minItems(_ n: Int) -> Self { Self { $0.minItems = n } }
    public static func maxItems(_ n: Int) -> Self { Self { $0.maxItems = n } }
}
