import Foundation

/// A JSON value, used for contract data: defaults, examples of structured values and JSON Schemas.
///
/// Objects keep their keys in insertion order; the contract writer sorts them, so output is deterministic.
public enum JSONValue: Sendable, Hashable {
    case null
    case bool(Bool)
    case int(Int)
    case double(Double)
    case string(String)
    case array([JSONValue])
    case object([(String, JSONValue)])

    public static func == (lhs: JSONValue, rhs: JSONValue) -> Bool {
        switch (lhs, rhs) {
        case (.null, .null): return true
        case let (.bool(a), .bool(b)): return a == b
        case let (.int(a), .int(b)): return a == b
        case let (.double(a), .double(b)): return a == b
        case let (.string(a), .string(b)): return a == b
        case let (.array(a), .array(b)): return a == b
        case let (.object(a), .object(b)):
            return a.count == b.count && zip(a, b).allSatisfy { $0.0 == $1.0 && $0.1 == $1.1 }
        default: return false
        }
    }

    public func hash(into hasher: inout Hasher) {
        switch self {
        case .null: hasher.combine(0)
        case .bool(let b): hasher.combine(b)
        case .int(let i): hasher.combine(i)
        case .double(let d): hasher.combine(d)
        case .string(let s): hasher.combine(s)
        case .array(let a): hasher.combine(a)
        case .object(let o):
            for (k, v) in o {
                hasher.combine(k)
                hasher.combine(v)
            }
        }
    }

    /// Looks up a key in an object.
    public subscript(key: String) -> JSONValue? {
        if case .object(let members) = self {
            return members.first { $0.0 == key }?.1
        }
        return nil
    }

    /// Encodes any `Encodable` value as a `JSONValue`, by way of `JSONEncoder`.
    public static func encoding<T: Encodable>(_ value: T) throws -> JSONValue {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(value)
        return try JSONDecoder().decode(JSONValue.self, from: data)
    }

    /// Compact JSON text, with object keys in their stored order.
    public var jsonText: String {
        switch self {
        case .null: return "null"
        case .bool(let b): return b ? "true" : "false"
        case .int(let i): return String(i)
        case .double(let d): return JSONValue.format(d)
        case .string(let s): return JSONValue.quote(s)
        case .array(let a): return "[" + a.map(\.jsonText).joined(separator: ",") + "]"
        case .object(let o): return "{" + o.map { JSONValue.quote($0.0) + ":" + $0.1.jsonText }.joined(separator: ",") + "}"
        }
    }

    /// Shortest round-trip decimal form of a finite double. Integral values keep a `.0`, so they stay floats.
    static func format(_ d: Double) -> String {
        precondition(d.isFinite, "JSON numbers must be finite")
        return "\(d)"
    }

    /// A JSON (and CUE) double-quoted string literal.
    static func quote(_ s: String) -> String {
        var out = "\""
        for scalar in s.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            case _ where scalar.value < 0x20 || scalar.value == 0x7F:
                out += String(format: "\\u%04x", scalar.value)
            default: out.unicodeScalars.append(scalar)
            }
        }
        return out + "\""
    }
}

extension JSONValue: Codable {
    private struct MemberKey: CodingKey {
        var stringValue: String
        var intValue: Int? { nil }
        init(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { nil }
    }

    public init(from decoder: any Decoder) throws {
        if let keyed = try? decoder.container(keyedBy: MemberKey.self) {
            self = .object(try keyed.allKeys.sorted { $0.stringValue < $1.stringValue }.map {
                ($0.stringValue, try keyed.decode(JSONValue.self, forKey: $0))
            })
            return
        }
        if var unkeyed = try? decoder.unkeyedContainer() {
            var items: [JSONValue] = []
            while !unkeyed.isAtEnd {
                items.append(try unkeyed.decode(JSONValue.self))
            }
            self = .array(items)
            return
        }
        let single = try decoder.singleValueContainer()
        if single.decodeNil() {
            self = .null
        } else if let b = try? single.decode(Bool.self) {
            self = .bool(b)
        } else if let i = try? single.decode(Int.self) {
            self = .int(i)
        } else if let d = try? single.decode(Double.self) {
            self = .double(d)
        } else {
            self = .string(try single.decode(String.self))
        }
    }

    public func encode(to encoder: any Encoder) throws {
        switch self {
        case .null:
            var c = encoder.singleValueContainer()
            try c.encodeNil()
        case .bool(let b):
            var c = encoder.singleValueContainer()
            try c.encode(b)
        case .int(let i):
            var c = encoder.singleValueContainer()
            try c.encode(i)
        case .double(let d):
            var c = encoder.singleValueContainer()
            try c.encode(d)
        case .string(let s):
            var c = encoder.singleValueContainer()
            try c.encode(s)
        case .array(let a):
            var c = encoder.unkeyedContainer()
            for item in a { try c.encode(item) }
        case .object(let o):
            var c = encoder.container(keyedBy: MemberKey.self)
            for (k, v) in o { try c.encode(v, forKey: MemberKey(stringValue: k)) }
        }
    }
}

extension JSONValue: ExpressibleByStringLiteral, ExpressibleByIntegerLiteral, ExpressibleByBooleanLiteral,
    ExpressibleByArrayLiteral, ExpressibleByDictionaryLiteral, ExpressibleByFloatLiteral
{
    public init(stringLiteral value: String) { self = .string(value) }
    public init(integerLiteral value: Int) { self = .int(value) }
    public init(booleanLiteral value: Bool) { self = .bool(value) }
    public init(floatLiteral value: Double) { self = .double(value) }
    public init(arrayLiteral elements: JSONValue...) { self = .array(elements) }
    public init(dictionaryLiteral elements: (String, JSONValue)...) { self = .object(elements) }
}
