import Foundation

/// A type that supplies its own JSON Schema instead of the one docuconf derives from its `Decodable`
/// conformance. Use it to add constraints (`minimum`, `pattern`, `description`) the derived schema lacks.
public protocol JSONSchemaProviding {
    static var jsonSchema: JSONValue { get }
}

/// Derives JSON Schemas from `Decodable` types (SPEC §4.6: schemas come from code).
///
/// Swift has no runtime reflection over `Decodable`, so the schema is recorded by decoding the type from a
/// probing decoder: each `decode(_:forKey:)` call adds a required property, each `decodeIfPresent` an optional
/// one, arrays record their element type and dictionaries their value type. This covers synthesized
/// conformances. String enums are recognised when they are `CaseIterable`. Types with a hand-written
/// `init(from:)` that validates values can conform to ``JSONSchemaProviding`` instead.
public enum JSONSchema {
    public struct GenerationError: Error, CustomStringConvertible, Sendable {
        public var description: String
    }

    public static func generate<T: Decodable>(_ type: T.Type) throws -> JSONValue {
        do {
            return try Probe.value(type, depth: 0).1.render()
        } catch let e as GenerationError {
            throw e
        } catch {
            throw GenerationError(
                description: "cannot derive a JSON Schema for \(T.self) from its Decodable conformance (\(error)). "
                    + "Conform it, or the nested type that fails, to JSONSchemaProviding.")
        }
    }

    /// The decoder docuconf uses for JSON config files and `json` variables. Dates are ISO 8601 strings,
    /// matching the derived schema.
    public static func makeJSONDecoder() -> JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }
}

// MARK: - Probe

final class SchemaNode {
    enum Kind {
        case unknown
        case leaf(JSONValue)
        case object(properties: [(String, SchemaNode)], required: [String])
        case array(SchemaNode?)
        case map(SchemaNode)
    }

    var kind: Kind = .unknown

    func addProperty(_ name: String, _ node: SchemaNode, required: Bool) {
        var props: [(String, SchemaNode)] = []
        var req: [String] = []
        if case .object(let p, let r) = kind {
            props = p
            req = r
        }
        if let i = props.firstIndex(where: { $0.0 == name }) {
            props[i].1 = node
        } else {
            props.append((name, node))
        }
        if required && !req.contains(name) { req.append(name) }
        kind = .object(properties: props, required: req)
    }

    func render() -> JSONValue {
        switch kind {
        case .unknown:
            return .object([])
        case .leaf(let s):
            return s
        case .object(let props, let req):
            var members: [(String, JSONValue)] = [("type", "object")]
            members.append(("properties", .object(props.map { ($0.0, $0.1.render()) })))
            if !req.isEmpty { members.append(("required", .array(req.map { .string($0) }))) }
            return .object(members)
        case .array(let item):
            return .object([("type", "array"), ("items", item?.render() ?? .object([]))])
        case .map(let value):
            return .object([("type", "object"), ("additionalProperties", value.render())])
        }
    }
}

enum Probe {
    static let mapKey = "__docuconf_probe__"
    static let maxDepth = 32

    static func leaf(_ type: String, _ extra: (String, JSONValue)...) -> SchemaNode {
        let n = SchemaNode()
        n.kind = .leaf(.object([("type", .string(type))] + extra))
        return n
    }

    /// A value of `T` and the schema node describing it.
    static func value<T: Decodable>(_ type: T.Type, depth: Int) throws -> (T, SchemaNode) {
        if let p = primitive(type) { return p }
        if let provider = T.self as? any JSONSchemaProviding.Type {
            let schema = provider.jsonSchema
            let n = SchemaNode()
            n.kind = .leaf(schema)
            let data = Data(example(schema).jsonText.utf8)
            return (try JSONSchema.makeJSONDecoder().decode(T.self, from: data), n)
        }
        if let cases = T.self as? any (CaseIterable & Encodable).Type, let e = try enumeration(cases, as: T.self) {
            return e
        }
        if depth > maxDepth {
            throw JSONSchema.GenerationError(description: "\(T.self) is nested more than \(maxDepth) levels deep (a recursive type?); conform it to JSONSchemaProviding")
        }
        let node = SchemaNode()
        let v = try T(from: ProbeDecoder(node: node, depth: depth + 1))
        return (v, node)
    }

    static func enumeration<C: CaseIterable & Encodable, T>(_ type: C.Type, as: T.Type) throws -> (T, SchemaNode)? {
        let encoded = try C.allCases.map { try JSONValue.encoding($0) }
        guard let first = C.allCases.first as? T, !encoded.isEmpty else { return nil }
        let n = SchemaNode()
        let types = Set(encoded.map { v -> String in
            switch v {
            case .string: "string"
            case .int: "integer"
            default: "number"
            }
        })
        n.kind = .leaf(.object([("type", .string(types.count == 1 ? types.first! : "string")), ("enum", .array(encoded))]))
        return (first, n)
    }

    static func primitive<T>(_ type: T.Type) -> (T, SchemaNode)? {
        func r<V>(_ v: V, _ n: SchemaNode) -> (T, SchemaNode)? { (v as! T, n) }
        switch type {
        case is String.Type: return r("", leaf("string"))
        case is Bool.Type: return r(false, leaf("boolean"))
        case is Int.Type: return r(0 as Int, leaf("integer"))
        case is Int8.Type: return r(0 as Int8, leaf("integer"))
        case is Int16.Type: return r(0 as Int16, leaf("integer"))
        case is Int32.Type: return r(0 as Int32, leaf("integer"))
        case is Int64.Type: return r(0 as Int64, leaf("integer"))
        case is UInt.Type: return r(0 as UInt, leaf("integer", ("minimum", 0)))
        case is UInt8.Type: return r(0 as UInt8, leaf("integer", ("minimum", 0)))
        case is UInt16.Type: return r(0 as UInt16, leaf("integer", ("minimum", 0)))
        case is UInt32.Type: return r(0 as UInt32, leaf("integer", ("minimum", 0)))
        case is UInt64.Type: return r(0 as UInt64, leaf("integer", ("minimum", 0)))
        case is Double.Type: return r(0 as Double, leaf("number"))
        case is Float.Type: return r(0 as Float, leaf("number"))
        case is Decimal.Type: return r(Decimal(0), leaf("number"))
        case is URL.Type: return r(URL(string: "https://example.invalid")!, leaf("string", ("format", "uri")))
        case is UUID.Type: return r(UUID(), leaf("string", ("format", "uuid")))
        case is Date.Type: return r(Date(timeIntervalSince1970: 0), leaf("string", ("format", "date-time")))
        case is Data.Type: return r(Data(), leaf("string", ("contentEncoding", "base64")))
        case is JSONValue.Type:
            let n = SchemaNode()
            n.kind = .leaf(.object([]))
            return r(JSONValue.null, n)
        default: return nil
        }
    }

    /// A minimal JSON value that satisfies a schema, to decode `JSONSchemaProviding` types while probing.
    static func example(_ schema: JSONValue) -> JSONValue {
        if case .array(let values)? = schema["enum"], let first = values.first { return first }
        if let c = schema["const"] { return c }
        if let d = schema["default"] { return d }
        let type: String
        switch schema["type"] {
        case .string(let t)?: type = t
        case .array(let ts)?: if case .string(let t)? = ts.first { type = t } else { type = "null" }
        default: type = schema["properties"] != nil ? "object" : "null"
        }
        switch type {
        case "string":
            switch schema["format"] {
            case .string("uri")?: return "https://example.invalid"
            case .string("date-time")?: return "1970-01-01T00:00:00Z"
            case .string("uuid")?: return "00000000-0000-0000-0000-000000000000"
            default:
                let n: Int
                if case .int(let m)? = schema["minLength"] { n = m } else { n = 0 }
                return .string(String(repeating: "a", count: n))
            }
        case "integer":
            if let m = schema["minimum"] { return m }
            return 0
        case "number":
            if let m = schema["minimum"] { return m }
            return 0.0
        case "boolean": return false
        case "array":
            if case .int(let n)? = schema["minItems"], n > 0, let items = schema["items"] {
                return .array(Array(repeating: example(items), count: n))
            }
            return []
        case "object":
            var members: [(String, JSONValue)] = []
            if case .array(let req)? = schema["required"], let props = schema["properties"] {
                for case .string(let name) in req {
                    members.append((name, props[name].map(example) ?? .null))
                }
            }
            return .object(members)
        default:
            return .null
        }
    }
}

struct ProbeDecoder: Decoder {
    let node: SchemaNode
    let depth: Int
    var codingPath: [any CodingKey] = []
    var userInfo: [CodingUserInfoKey: Any] { [:] }

    func container<Key: CodingKey>(keyedBy type: Key.Type) throws -> KeyedDecodingContainer<Key> {
        if case .unknown = node.kind { node.kind = .object(properties: [], required: []) }
        return KeyedDecodingContainer(ProbeKeyed<Key>(node: node, depth: depth, codingPath: codingPath))
    }

    func unkeyedContainer() throws -> any UnkeyedDecodingContainer {
        if case .unknown = node.kind { node.kind = .array(nil) }
        return ProbeUnkeyed(node: node, depth: depth, codingPath: codingPath)
    }

    func singleValueContainer() throws -> any SingleValueDecodingContainer {
        ProbeSingle(node: node, depth: depth, codingPath: codingPath)
    }
}

struct ProbeKeyed<Key: CodingKey>: KeyedDecodingContainerProtocol {
    let node: SchemaNode
    let depth: Int
    var codingPath: [any CodingKey]

    /// Dictionaries iterate `allKeys`; a struct's `CodingKeys` rejects the probe key, so only maps see it.
    var allKeys: [Key] { Key(stringValue: Probe.mapKey).map { [$0] } ?? [] }

    func contains(_ key: Key) -> Bool { true }
    func decodeNil(forKey key: Key) throws -> Bool { false }

    private func record(_ key: Key, _ child: SchemaNode, required: Bool) {
        if key.stringValue == Probe.mapKey {
            node.kind = .map(child)
        } else {
            node.addProperty(key.stringValue, child, required: required)
        }
    }

    func decode<T: Decodable>(_ type: T.Type, forKey key: Key) throws -> T {
        let (v, child) = try Probe.value(type, depth: depth)
        record(key, child, required: true)
        return v
    }

    func decodeIfPresent<T: Decodable>(_ type: T.Type, forKey key: Key) throws -> T? {
        let (v, child) = try Probe.value(type, depth: depth)
        record(key, child, required: false)
        return v
    }

    func decode(_ type: Bool.Type, forKey key: Key) throws -> Bool { try decode(type as Bool.Type, key) }
    func decode(_ type: String.Type, forKey key: Key) throws -> String { try decode(type as String.Type, key) }
    func decode(_ type: Double.Type, forKey key: Key) throws -> Double { try decode(type as Double.Type, key) }
    func decode(_ type: Float.Type, forKey key: Key) throws -> Float { try decode(type as Float.Type, key) }
    func decode(_ type: Int.Type, forKey key: Key) throws -> Int { try decode(type as Int.Type, key) }
    func decode(_ type: Int8.Type, forKey key: Key) throws -> Int8 { try decode(type as Int8.Type, key) }
    func decode(_ type: Int16.Type, forKey key: Key) throws -> Int16 { try decode(type as Int16.Type, key) }
    func decode(_ type: Int32.Type, forKey key: Key) throws -> Int32 { try decode(type as Int32.Type, key) }
    func decode(_ type: Int64.Type, forKey key: Key) throws -> Int64 { try decode(type as Int64.Type, key) }
    func decode(_ type: UInt.Type, forKey key: Key) throws -> UInt { try decode(type as UInt.Type, key) }
    func decode(_ type: UInt8.Type, forKey key: Key) throws -> UInt8 { try decode(type as UInt8.Type, key) }
    func decode(_ type: UInt16.Type, forKey key: Key) throws -> UInt16 { try decode(type as UInt16.Type, key) }
    func decode(_ type: UInt32.Type, forKey key: Key) throws -> UInt32 { try decode(type as UInt32.Type, key) }
    func decode(_ type: UInt64.Type, forKey key: Key) throws -> UInt64 { try decode(type as UInt64.Type, key) }

    private func decode<T: Decodable>(_ type: T.Type, _ key: Key) throws -> T {
        let (v, child) = try Probe.value(type, depth: depth)
        record(key, child, required: true)
        return v
    }

    func decodeIfPresent(_ type: Bool.Type, forKey key: Key) throws -> Bool? { try opt(type, key) }
    func decodeIfPresent(_ type: String.Type, forKey key: Key) throws -> String? { try opt(type, key) }
    func decodeIfPresent(_ type: Double.Type, forKey key: Key) throws -> Double? { try opt(type, key) }
    func decodeIfPresent(_ type: Float.Type, forKey key: Key) throws -> Float? { try opt(type, key) }
    func decodeIfPresent(_ type: Int.Type, forKey key: Key) throws -> Int? { try opt(type, key) }
    func decodeIfPresent(_ type: Int8.Type, forKey key: Key) throws -> Int8? { try opt(type, key) }
    func decodeIfPresent(_ type: Int16.Type, forKey key: Key) throws -> Int16? { try opt(type, key) }
    func decodeIfPresent(_ type: Int32.Type, forKey key: Key) throws -> Int32? { try opt(type, key) }
    func decodeIfPresent(_ type: Int64.Type, forKey key: Key) throws -> Int64? { try opt(type, key) }
    func decodeIfPresent(_ type: UInt.Type, forKey key: Key) throws -> UInt? { try opt(type, key) }
    func decodeIfPresent(_ type: UInt8.Type, forKey key: Key) throws -> UInt8? { try opt(type, key) }
    func decodeIfPresent(_ type: UInt16.Type, forKey key: Key) throws -> UInt16? { try opt(type, key) }
    func decodeIfPresent(_ type: UInt32.Type, forKey key: Key) throws -> UInt32? { try opt(type, key) }
    func decodeIfPresent(_ type: UInt64.Type, forKey key: Key) throws -> UInt64? { try opt(type, key) }

    private func opt<T: Decodable>(_ type: T.Type, _ key: Key) throws -> T? {
        let (v, child) = try Probe.value(type, depth: depth)
        record(key, child, required: false)
        return v
    }

    func nestedContainer<NestedKey: CodingKey>(keyedBy type: NestedKey.Type, forKey key: Key) throws -> KeyedDecodingContainer<NestedKey> {
        let child = SchemaNode()
        child.kind = .object(properties: [], required: [])
        record(key, child, required: true)
        return KeyedDecodingContainer(ProbeKeyed<NestedKey>(node: child, depth: depth + 1, codingPath: codingPath + [key]))
    }

    func nestedUnkeyedContainer(forKey key: Key) throws -> any UnkeyedDecodingContainer {
        let child = SchemaNode()
        child.kind = .array(nil)
        record(key, child, required: true)
        return ProbeUnkeyed(node: child, depth: depth + 1, codingPath: codingPath + [key])
    }

    func superDecoder() throws -> any Decoder { ProbeDecoder(node: node, depth: depth, codingPath: codingPath) }

    func superDecoder(forKey key: Key) throws -> any Decoder {
        let child = SchemaNode()
        record(key, child, required: true)
        return ProbeDecoder(node: child, depth: depth + 1, codingPath: codingPath + [key])
    }
}

struct ProbeUnkeyed: UnkeyedDecodingContainer {
    let node: SchemaNode
    let depth: Int
    var codingPath: [any CodingKey]
    var count: Int? { nil }
    var currentIndex = 0
    var isAtEnd: Bool { currentIndex > 0 }

    init(node: SchemaNode, depth: Int, codingPath: [any CodingKey]) {
        self.node = node
        self.depth = depth
        self.codingPath = codingPath
    }

    mutating func decodeNil() throws -> Bool { false }

    mutating func decode<T: Decodable>(_ type: T.Type) throws -> T {
        let (v, child) = try Probe.value(type, depth: depth)
        node.kind = .array(child)
        currentIndex += 1
        return v
    }

    mutating func nestedContainer<NestedKey: CodingKey>(keyedBy type: NestedKey.Type) throws -> KeyedDecodingContainer<NestedKey> {
        let child = SchemaNode()
        child.kind = .object(properties: [], required: [])
        node.kind = .array(child)
        currentIndex += 1
        return KeyedDecodingContainer(ProbeKeyed<NestedKey>(node: child, depth: depth + 1, codingPath: codingPath))
    }

    mutating func nestedUnkeyedContainer() throws -> any UnkeyedDecodingContainer {
        let child = SchemaNode()
        child.kind = .array(nil)
        node.kind = .array(child)
        currentIndex += 1
        return ProbeUnkeyed(node: child, depth: depth + 1, codingPath: codingPath)
    }

    mutating func superDecoder() throws -> any Decoder {
        let child = SchemaNode()
        node.kind = .array(child)
        currentIndex += 1
        return ProbeDecoder(node: child, depth: depth + 1, codingPath: codingPath)
    }
}

struct ProbeSingle: SingleValueDecodingContainer {
    let node: SchemaNode
    let depth: Int
    var codingPath: [any CodingKey]

    func decodeNil() -> Bool { false }

    func decode<T: Decodable>(_ type: T.Type) throws -> T {
        let (v, child) = try Probe.value(type, depth: depth)
        node.kind = child.kind
        return v
    }
}
