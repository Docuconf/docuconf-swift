import Foundation

/// A type an ``Env`` variable can hold: a supported type, or an optional of one.
public protocol EnvValue: Sendable {
    associatedtype Base: EnvBaseValue
    /// Whether the variable may be absent (`Value?`).
    static var isOptional: Bool { get }
    /// Wraps a loaded base value, or absence. Returns `nil` when `Self` cannot represent absence.
    static func wrap(_ base: Base?) -> Self?
    /// The base value, for defaults.
    var base: Base? { get }
}

/// A supported variable type (SPEC §4.3): `String`, `Int`, `Double`, `Bool`, `Duration`, `URL`, `[String]`,
/// `[Int]` (or a list of any fixed-width integer), a ``ConfigEnum`` or a ``JSONConfigValue``.
public protocol EnvBaseValue: EnvValue where Base == Self {
    static var varType: VarType { get }
    /// Adds type-specific contract fields: enum values, list item type, JSON Schema.
    static func describe(_ spec: inout VarSpec) throws
    /// Converts a parsed and checked value. Throws ``ValueConversionError`` (for example, JSON that does not
    /// decode into the app's type).
    init(parsed: ParsedValue) throws
    /// The value in parsed form, to check a default against the constraints.
    var parsed: ParsedValue { get }
    /// The value as contract data, for `default`.
    var contractValue: JSONValue { get }
}

/// Why a parsed value could not become the app's type.
public struct ValueConversionError: Error, Sendable {
    public var code: ViolationCode
    public var message: String

    public init(_ code: ViolationCode, _ message: String) {
        self.code = code
        self.message = message
    }
}

extension EnvBaseValue {
    public static var isOptional: Bool { false }
    public static func wrap(_ base: Self?) -> Self? { base }
    public var base: Self? { self }
    public static func describe(_ spec: inout VarSpec) throws {}

    static func mismatch(_ p: ParsedValue) -> ValueConversionError {
        ValueConversionError(.invalidType, "internal: \(p) is not a \(Self.self)")
    }
}

extension Optional: EnvValue where Wrapped: EnvBaseValue {
    public typealias Base = Wrapped
    public static var isOptional: Bool { true }
    public static func wrap(_ base: Wrapped?) -> Wrapped?? { .some(base) }
    public var base: Wrapped? { self }
}

extension String: EnvBaseValue {
    public static var varType: VarType { .string }
    public init(parsed: ParsedValue) throws {
        guard case .string(let s) = parsed else { throw Self.mismatch(parsed) }
        self = s
    }
    public var parsed: ParsedValue { .string(self) }
    public var contractValue: JSONValue { .string(self) }
}

extension Int: EnvBaseValue {
    public static var varType: VarType { .int }
    public init(parsed: ParsedValue) throws {
        guard case .int(let i) = parsed else { throw Self.mismatch(parsed) }
        self = i
    }
    public var parsed: ParsedValue { .int(self) }
    public var contractValue: JSONValue { .int(self) }
}

extension Double: EnvBaseValue {
    public static var varType: VarType { .float }
    public init(parsed: ParsedValue) throws {
        guard case .double(let d) = parsed else { throw Self.mismatch(parsed) }
        self = d
    }
    public var parsed: ParsedValue { .double(self) }
    public var contractValue: JSONValue { .double(self) }
}

extension Bool: EnvBaseValue {
    public static var varType: VarType { .bool }
    public init(parsed: ParsedValue) throws {
        guard case .bool(let b) = parsed else { throw Self.mismatch(parsed) }
        self = b
    }
    public var parsed: ParsedValue { .bool(self) }
    public var contractValue: JSONValue { .bool(self) }
}

extension Duration: EnvBaseValue {
    public static var varType: VarType { .duration }
    public init(parsed: ParsedValue) throws {
        guard case .duration(let d) = parsed else { throw Self.mismatch(parsed) }
        self = d
    }
    public var parsed: ParsedValue { .duration(self) }
    public var contractValue: JSONValue { .string(GoDuration.format(self)) }
}

extension URL: EnvBaseValue {
    public static var varType: VarType { .url }
    public init(parsed: ParsedValue) throws {
        guard case .url(let s) = parsed else { throw Self.mismatch(parsed) }
        guard let u = URL(string: s) else { throw ValueConversionError(.invalidType, "is not a valid URL") }
        self = u
    }
    public var parsed: ParsedValue { .url(absoluteString) }
    public var contractValue: JSONValue { .string(absoluteString) }
}

/// A fixed-width integer variable other than `Int` (`Int32`, `UInt16`, ...). It is an `int` in the contract, and a
/// type narrower than 64 bits exports its own range as `min` / `max`, so the platform never sends a value the app
/// cannot hold. `.range`, `.min` and `.max` narrow it further.
public protocol FixedWidthEnvValue: EnvBaseValue, FixedWidthInteger, ListItem {}

extension FixedWidthEnvValue {
    public static var varType: VarType { .int }
    public static func describe(_ spec: inout VarSpec) throws {
        let (lo, hi) = itemBounds
        if let lo { spec.min = .int(lo) }
        if let hi { spec.max = .int(hi) }
    }
    public init(parsed: ParsedValue) throws {
        guard case .int(let i) = parsed else { throw Self.mismatch(parsed) }
        guard let v = Self(exactly: i) else { throw ValueConversionError(.outOfRange, "is outside the range of \(Self.self)") }
        self = v
    }
    public var parsed: ParsedValue { .int(Int(clamping: self)) }
    public var contractValue: JSONValue { .int(Int(clamping: self)) }
}

extension Int8: FixedWidthEnvValue {}
extension Int16: FixedWidthEnvValue {}
extension Int32: FixedWidthEnvValue {}
extension Int64: FixedWidthEnvValue {}
extension UInt8: FixedWidthEnvValue {}
extension UInt16: FixedWidthEnvValue {}
extension UInt32: FixedWidthEnvValue {}

/// `Float` is not a variable type: values are read as 64-bit floats. The conformance exists only so the
/// compiler explains that.
@available(*, unavailable, message: "docuconf reads floating-point variables as Double; declare the property as Double")
extension Float: EnvBaseValue {
    public static var varType: VarType { .float }
    public init(parsed: ParsedValue) throws { fatalError("unavailable") }
    public var parsed: ParsedValue { fatalError("unavailable") }
    public var contractValue: JSONValue { fatalError("unavailable") }
}

/// An item type of a `list` variable: `String`, or a fixed-width integer (`Int`, `Int32`, `UInt16`, ...).
///
/// An integer type narrower than 64 bits exports its range as the list's `itemMin` / `itemMax` (SPEC §5), so the
/// platform never sends an item the app cannot hold.
public protocol ListItem: Sendable {
    static var itemType: VarType { get }
    /// The range of values the type holds, where it is narrower than a 64-bit signed integer.
    static var itemBounds: (min: Int?, max: Int?) { get }
    /// The items of a parsed list, or `nil` when the list holds the other item type or an item does not fit.
    static func items(of parsed: ParsedValue) -> [Self]?
    /// A list of these items in parsed form.
    static func parsed(_ items: [Self]) -> ParsedValue
    /// The item as contract data.
    var itemContractValue: JSONValue { get }
}

extension String: ListItem {
    public static var itemType: VarType { .string }
    public static var itemBounds: (min: Int?, max: Int?) { (nil, nil) }
    public static func items(of parsed: ParsedValue) -> [String]? {
        if case .stringList(let l) = parsed { return l }
        return nil
    }
    public static func parsed(_ items: [String]) -> ParsedValue { .stringList(items) }
    public var itemContractValue: JSONValue { .string(self) }
}

extension ListItem where Self: FixedWidthInteger {
    public static var itemType: VarType { .int }
    public static var itemBounds: (min: Int?, max: Int?) {
        (Self.min > Int64.min ? Int(exactly: Self.min) : nil, Self.max < Int64.max ? Int(exactly: Self.max) : nil)
    }
    public static func items(of parsed: ParsedValue) -> [Self]? {
        guard case .intList(let l) = parsed else { return nil }
        var out: [Self] = []
        out.reserveCapacity(l.count)
        for i in l {
            guard let v = Self(exactly: i) else { return nil }
            out.append(v)
        }
        return out
    }
    public static func parsed(_ items: [Self]) -> ParsedValue { .intList(items.map { Int(clamping: $0) }) }
    public var itemContractValue: JSONValue { .int(Int(clamping: self)) }
}

extension Int: ListItem {}
extension Int8: ListItem {}
extension Int16: ListItem {}
extension Int32: ListItem {}
extension Int64: ListItem {}
extension UInt: ListItem {}
extension UInt8: ListItem {}
extension UInt16: ListItem {}
extension UInt32: ListItem {}
extension UInt64: ListItem {}

extension Array: EnvValue where Element: ListItem {}

extension Array: EnvBaseValue where Element: ListItem {
    public static var varType: VarType { .list }
    public static func describe(_ spec: inout VarSpec) throws {
        spec.items = Element.itemType
        (spec.itemMin, spec.itemMax) = Element.itemBounds
    }
    public init(parsed: ParsedValue) throws {
        guard let items = Element.items(of: parsed) else {
            if case .intList = parsed, Element.itemType == .int {
                throw ValueConversionError(.outOfRange, "has an item outside the range of \(Element.self)")
            }
            throw Self.mismatch(parsed)
        }
        self = items
    }
    public var parsed: ParsedValue { Element.parsed(self) }
    public var contractValue: JSONValue { .array(map(\.itemContractValue)) }
}

/// A string enum as an `enum` variable. Its cases' raw values are the allowed values.
///
/// ```swift
/// enum LogLevel: String, ConfigEnum { case debug, info, warn, error }
/// ```
public protocol ConfigEnum: EnvBaseValue, RawRepresentable<String>, CaseIterable, JSONSchemaProviding {}

extension ConfigEnum {
    public static var varType: VarType { .enum }
    public static func describe(_ spec: inout VarSpec) throws { spec.values = allCases.map(\.rawValue) }
    public init(parsed: ParsedValue) throws {
        guard case .enumCase(let s) = parsed else { throw Self.mismatch(parsed) }
        guard let v = Self(rawValue: s) else { throw ValueConversionError(.notInEnum, "is not an allowed value") }
        self = v
    }
    public var parsed: ParsedValue { .enumCase(rawValue) }
    public var contractValue: JSONValue { .string(rawValue) }
    public static var jsonSchema: JSONValue {
        ["type": "string", "enum": .array(allCases.map { .string($0.rawValue) })]
    }
}

/// A structured value in one variable, sent as compact JSON (`type: "json"`). The contract carries a JSON
/// Schema derived from the type, so the platform checks values against the type the app decodes.
///
/// ```swift
/// struct RateLimit: JSONConfigValue { var requestsPerSecond: Int; var burst: Int }
/// ```
public protocol JSONConfigValue: EnvBaseValue, Codable {}

extension JSONConfigValue {
    public static var varType: VarType { .json }
    public static func describe(_ spec: inout VarSpec) throws { spec.schema = try JSONSchema.generate(Self.self) }
    public init(parsed: ParsedValue) throws {
        guard case .json(let text) = parsed else { throw Self.mismatch(parsed) }
        let data = Data(text.utf8)
        guard (try? JSONDecoder().decode(JSONValue.self, from: data)) != nil else {
            throw ValueConversionError(.invalidType, "is not valid JSON")
        }
        do {
            self = try JSONSchema.makeJSONDecoder().decode(Self.self, from: data)
        } catch let e as DecodingError {
            throw ValueConversionError(.schemaMismatch, "does not match \(Self.self): \(DecodingErrorText.describe(e))")
        }
    }
    public var parsed: ParsedValue { .json(contractValue.jsonText) }
    public var contractValue: JSONValue { (try? JSONValue.encoding(self)) ?? .null }
}

/// Describes decoding errors by path and kind, never by value, so secrets stay out of messages.
public enum DecodingErrorText {
    public static func describe(_ error: DecodingError) -> String {
        func path(_ p: [any CodingKey]) -> String {
            p.isEmpty ? "$" : "$" + p.map { $0.intValue.map { "[\($0)]" } ?? ".\($0.stringValue)" }.joined()
        }
        switch error {
        case .keyNotFound(let key, let ctx): return "\(path(ctx.codingPath + [key])) is required"
        case .typeMismatch(let type, let ctx): return "\(path(ctx.codingPath)) is not \(article(type))"
        case .valueNotFound(let type, let ctx): return "\(path(ctx.codingPath)) is null, expected \(article(type))"
        case .dataCorrupted(let ctx): return "\(path(ctx.codingPath)): \(ctx.debugDescription)"
        @unknown default: return "\(error)"
        }
    }

    static func article(_ type: Any.Type) -> String {
        switch type {
        case is String.Type: "a string"
        case is Bool.Type: "a boolean"
        case is Double.Type, is Float.Type: "a number"
        case is any BinaryInteger.Type: "an integer"
        case is [Any].Type: "an array"
        case is [String: Any].Type: "an object"
        default: "a \(type)"
        }
    }
}
