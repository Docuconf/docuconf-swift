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
        self.init(defaultValue: wrappedValue, key, description, rules)
    }

    /// A variable with a default, with the description labelled:
    /// `@Env("http.port", description: "HTTP listen port") var port = 8080`.
    public init(wrappedValue: Value, _ key: String, description: String, _ rules: VarRule<Value.Base>...) {
        self.init(defaultValue: wrappedValue, key, description, rules)
    }

    /// A variable with no default: required, or `nil` when unset if `Value` is optional.
    public init(_ key: String, _ description: String, _ rules: VarRule<Value.Base>...) {
        self.init(noDefault: key, description, rules)
    }

    /// A variable with no default, with the description labelled.
    public init(_ key: String, description: String, _ rules: VarRule<Value.Base>...) {
        self.init(noDefault: key, description, rules)
    }

    private init(defaultValue: Value, _ key: String, _ description: String, _ rules: [VarRule<Value.Base>]) {
        var spec = Self.makeSpec(key, description, rules)
        if let d = defaultValue.base {
            spec.defaultValue = d.contractValue
            spec.defaultParsed = d.parsed
        }
        self.spec = spec
        self.box = Box(defaultValue)
    }

    private init(noDefault key: String, _ description: String, _ rules: [VarRule<Value.Base>]) {
        var spec = Self.makeSpec(key, description, rules)
        spec.required = !Value.isOptional
        self.spec = spec
        self.box = Box(Value.wrap(nil))
    }

    static func makeSpec(_ key: String, _ description: String, _ rules: [VarRule<Value.Base>]) -> VarSpec {
        let doc = DocText.split(description)
        var spec = VarSpec(name: EnvName.forKey(key), key: key, type: Value.Base.varType, description: doc.description)
        spec.details = doc.details
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
/// `.items` for lists, `.itemRange` for lists of integers.
public struct VarRule<Base>: Sendable {
    let apply: @Sendable (inout VarSpec) -> Void

    public init(_ apply: @escaping @Sendable (inout VarSpec) -> Void) { self.apply = apply }

    /// The value must come from a secret reference. It is never printed, exported or given a default.
    public static var secret: Self { Self { $0.secret = true } }
    /// Free-form grouping for docs (`database`, `http`).
    public static func group(_ name: String) -> Self { Self { $0.group = name } }
    /// Long-form documentation in CommonMark: why the input exists and when to change it. Docs only, never read
    /// at runtime; not blank, and at most 4000 characters. Replaces the details taken from the description's
    /// later paragraphs (``DocText``).
    public static func details(_ text: String) -> Self { Self { $0.details = text } }
    /// Example values, for docs.
    public static func examples(_ values: String...) -> Self { Self { $0.examples = values } }
    /// The variable is deprecated; docuconf warns at boot when it is set.
    public static func deprecated(_ message: String, replacedBy: String? = nil) -> Self {
        Self { $0.deprecated = Deprecation(message: message, replacedBy: replacedBy) }
    }
}

extension VarRule where Base: EnvBaseValue & FixedWidthInteger {
    public static func range(_ r: ClosedRange<Base>) -> Self {
        Self { $0.min = .int(Int(clamping: r.lowerBound)); $0.max = .int(Int(clamping: r.upperBound)) }
    }
    /// A half-open range: `.range(1..<65536)` is `.range(1...65535)`.
    public static func range(_ r: Range<Base>) -> Self {
        Self { spec in
            guard !r.isEmpty else {
                spec.problems.append("\(spec.name): range \(r) is empty")
                return
            }
            spec.min = .int(Int(clamping: r.lowerBound))
            spec.max = .int(Int(clamping: r.upperBound - 1))
        }
    }
    public static func min(_ v: Base) -> Self { Self { $0.min = .int(Int(clamping: v)) } }
    public static func max(_ v: Base) -> Self { Self { $0.max = .int(Int(clamping: v)) } }
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
    /// The longest URL accepted, in Unicode scalars (code points), as the string is given.
    public static func maxLength(_ n: Int) -> Self { Self { $0.maxLength = n } }
}

extension VarRule where Base: JSONConfigValue {
    /// The longest value accepted, in Unicode scalars (code points) of its wire string: the raw value as received
    /// at boot, the compact JSON for a default.
    public static func maxLength(_ n: Int) -> Self { Self { $0.maxLength = n } }
}

extension VarRule where Base: EnvBaseValue & RangeReplaceableCollection, Base.Element == String {
    /// Bounds on the length of every item of a string list (`itemMinLength`, `itemMaxLength`), in Unicode
    /// scalars (code points), checked after the list is split, so separators never count.
    public static func itemLength(_ r: ClosedRange<Int>) -> Self {
        Self { $0.itemMinLength = r.lowerBound; $0.itemMaxLength = r.upperBound }
    }
    public static func itemMinLength(_ n: Int) -> Self { Self { $0.itemMinLength = n } }
    public static func itemMaxLength(_ n: Int) -> Self { Self { $0.itemMaxLength = n } }
}

extension VarRule where Base: EnvBaseValue & RangeReplaceableCollection, Base.Element: ListItem {
    /// The `csv` separator (`,` by default). docuconf splits the value itself, on every occurrence, and never
    /// trims an item (SPEC §5).
    public static func separator(_ s: String) -> Self { Self { $0.separator = s } }
    public static func items(_ r: ClosedRange<Int>) -> Self { Self { $0.minItems = r.lowerBound; $0.maxItems = r.upperBound } }
    public static func minItems(_ n: Int) -> Self { Self { $0.minItems = n } }
    public static func maxItems(_ n: Int) -> Self { Self { $0.maxItems = n } }
}

extension VarRule where Base: EnvBaseValue & RangeReplaceableCollection, Base.Element: ListItem & FixedWidthInteger {
    /// Bounds on every item of an integer list (`itemMin`, `itemMax`). They must lie within the item type's own
    /// range, which a narrow type (`[UInt16]`) exports without this rule.
    public static func itemRange(_ r: ClosedRange<Int>) -> Self {
        Self { spec in
            checkItemBound(r.lowerBound, "itemMin", &spec)
            checkItemBound(r.upperBound, "itemMax", &spec)
            spec.itemMin = r.lowerBound
            spec.itemMax = r.upperBound
        }
    }
    public static func itemMin(_ n: Int) -> Self { Self { checkItemBound(n, "itemMin", &$0); $0.itemMin = n } }
    public static func itemMax(_ n: Int) -> Self { Self { checkItemBound(n, "itemMax", &$0); $0.itemMax = n } }

    private static func checkItemBound(_ n: Int, _ field: String, _ spec: inout VarSpec) {
        let (lo, hi) = Base.Element.itemBounds
        if lo.map({ n < $0 }) ?? false || hi.map({ n > $0 }) ?? false {
            spec.problems.append("\(spec.name): \(field) \(n) is outside the range of \(Base.Element.self)")
        }
    }
}

// MARK: - Printing

/// How a loaded value is shown by `print`, `dump`, string interpolation and debuggers: the value itself, or
/// `<redacted>` for a secret, so logging a whole configuration struct never leaks one.
package enum Redaction {
    package static let redacted = "<redacted>"
    package static let notLoaded = "<not loaded>"
}

extension Box: CustomReflectable {
    /// Hides the stored value from `dump` and `Mirror`.
    package var customMirror: Mirror { Mirror(self, children: [:]) }
}

extension Env: CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    /// The value, or `<redacted>` for a secret. `print(config)` shows each variable this way.
    public var description: String { shown(debug: false) }

    public var debugDescription: String { shown(debug: true) }

    /// `dump(config)` shows the same text as `description`, and never the spec or the storage.
    public var customMirror: Mirror { Mirror(self, children: [:], displayStyle: nil) }

    private func shown(debug: Bool) -> String {
        guard let v = box.value else { return Redaction.notLoaded }
        if spec.secret { return Redaction.redacted }
        guard let base = v.base else { return "nil" }
        return debug ? String(reflecting: base) : String(describing: base)
    }
}
