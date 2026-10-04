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
/// `[Int]`, a ``ConfigEnum`` or a ``JSONConfigValue``.
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

/// An item type of a `list` variable: `String` or `Int`.
public protocol ListItem: Sendable {
    static var itemType: VarType { get }
}

extension String: ListItem {
    public static var itemType: VarType { .string }
}

extension Int: ListItem {
    public static var itemType: VarType { .int }
}

extension Array: EnvValue where Element: ListItem {}

extension Array: EnvBaseValue where Element: ListItem {
    public static var varType: VarType { .list }
    public static func describe(_ spec: inout VarSpec) throws { spec.items = Element.itemType }
    public init(parsed: ParsedValue) throws {
        switch parsed {
        case .stringList(let l) where Element.self == String.self: self = l as! [Element]
        case .intList(let l) where Element.self == Int.self: self = l as! [Element]
        default: throw Self.mismatch(parsed)
        }
    }
    public var parsed: ParsedValue {
        if let s = self as? [String] { return .stringList(s) }
        return .intList(self as! [Int])
    }
    public var contractValue: JSONValue {
        .array(map { ($0 as? String).map(JSONValue.string) ?? .int($0 as! Int) })
    }
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
