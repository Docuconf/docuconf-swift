import Foundation

/// Validates JSON documents against the JSON Schema subset docuconf contracts use (draft 2020-12 keywords), so
/// contract-first mode can check a `json` variable against its `schema` (SPEC §4.3), as the Go, Python and Ruby
/// SDKs do.
///
/// Supported: `type`, `enum`, `const`, `properties`, `required`, `additionalProperties`, `minProperties`,
/// `maxProperties`, `items`, `minItems`, `maxItems`, `uniqueItems`, `minimum`, `maximum`, `exclusiveMinimum`,
/// `exclusiveMaximum`, `multipleOf`, `minLength`, `maxLength` (in Unicode scalars), `pattern` (RE2), `anyOf`,
/// `oneOf`, `allOf` and `not`, plus annotations that never fail (`$schema`, `title`, `description`, `format`,
/// ...). A schema with any other keyword (`$ref`, `patternProperties`, ...) is rejected by ``problems(in:)``
/// rather than half-enforced.
public enum JSONSchemaValidator {
    /// Keywords the validator enforces or, for annotations, may safely ignore.
    public static let supportedKeywords: Set<String> = [
        "$schema", "$id", "$comment", "title", "description", "default", "examples", "format", "deprecated",
        "readOnly", "writeOnly", "contentEncoding", "contentMediaType",
        "type", "enum", "const", "properties", "required", "additionalProperties", "minProperties", "maxProperties",
        "items", "minItems", "maxItems", "uniqueItems", "minimum", "maximum", "exclusiveMinimum", "exclusiveMaximum",
        "multipleOf", "minLength", "maxLength", "pattern", "anyOf", "oneOf", "allOf", "not",
    ]
    static let types: Set<String> = ["object", "array", "string", "integer", "number", "boolean", "null"]

    /// What in `schema` the validator could not enforce: unknown keywords, unknown types, patterns outside RE2,
    /// malformed keyword values. Empty when the schema can be enforced in full.
    public static func problems(in schema: JSONValue, path: String = "") -> [String] {
        let here = path.isEmpty ? "/" : path
        switch schema {
        case .bool: return []
        case .object(let members):
            var out: [String] = []
            for (k, v) in members {
                let at = "\(path)/\(k)"
                guard supportedKeywords.contains(k) else {
                    out.append("\(at): keyword \(k) is not supported by the docuconf validator")
                    continue
                }
                switch k {
                case "properties":
                    guard case .object(let props) = v else { out.append("\(at): must be an object"); continue }
                    for (pk, ps) in props { out += problems(in: ps, path: "\(at)/\(pk)") }
                case "items", "not":
                    out += problems(in: v, path: at)
                case "additionalProperties":
                    out += problems(in: v, path: at)
                case "anyOf", "oneOf", "allOf":
                    guard case .array(let subs) = v, !subs.isEmpty else { out.append("\(at): must be a non-empty array"); continue }
                    for (i, s) in subs.enumerated() { out += problems(in: s, path: "\(at)/\(i)") }
                case "required":
                    guard case .array(let names) = v, names.allSatisfy({ if case .string = $0 { true } else { false } }) else {
                        out.append("\(at): must be an array of strings")
                        continue
                    }
                case "enum":
                    if case .array = v {} else { out.append("\(at): must be an array") }
                case "type":
                    let names: [JSONValue]
                    if case .array(let a) = v { names = a } else { names = [v] }
                    for t in names {
                        guard case .string(let s) = t, types.contains(s) else { out.append("\(at): unknown type \(t.jsonText)"); continue }
                    }
                case "pattern":
                    guard case .string(let p) = v else { out.append("\(at): must be a string"); continue }
                    if let problem = RE2.problem(in: p) { out.append("\(at): \(problem)") }
                case "minimum", "maximum", "exclusiveMinimum", "exclusiveMaximum", "multipleOf":
                    if number(v) == nil { out.append("\(at): must be a number") }
                    if k == "multipleOf", let m = number(v), m <= 0 { out.append("\(at): must be above 0") }
                case "minLength", "maxLength", "minItems", "maxItems", "minProperties", "maxProperties":
                    guard case .int(let n) = v, n >= 0 else { out.append("\(at): must be a non-negative integer"); continue }
                case "uniqueItems":
                    if case .bool = v {} else { out.append("\(at): must be a boolean") }
                default:
                    break
                }
            }
            return out
        default:
            return ["\(here): a schema must be an object or a boolean"]
        }
    }

    /// Validates `value` against `schema`. Returns "path: message" strings, empty when it is valid. Messages name
    /// the location and the rule broken, never a value found; but locations and unexpected property names come from
    /// the document, so a caller reporting on a secret should not show them.
    public static func validate(_ value: JSONValue, against schema: JSONValue, path: String = "") -> [String] {
        let here = path.isEmpty ? "/" : path
        switch schema {
        case .bool(true): return []
        case .bool(false): return ["\(here): no value is allowed here"]
        case .object(let members) where members.isEmpty: return []
        case .object: break
        default: return []
        }
        if let t = schema["type"] {
            let names: [String]
            if case .array(let a) = t {
                names = a.compactMap { if case .string(let s) = $0 { s } else { nil } }
            } else if case .string(let s) = t {
                names = [s]
            } else {
                names = []
            }
            if !names.isEmpty, !names.contains(where: { typeMatches($0, value) }) {
                return ["\(here): expected \(names.joined(separator: " or ")), got \(typeName(value))"]
            }
        }
        var errors: [String] = []
        if case .array(let options)? = schema["enum"], !options.contains(where: { equal($0, value) }) {
            errors.append("\(here): must be one of \(options.map(\.jsonText).joined(separator: ", "))")
        }
        if let c = schema["const"], !equal(c, value) {
            errors.append("\(here): must equal \(c.jsonText)")
        }
        switch value {
        case .object(let o): errors += validateObject(schema, o, path)
        case .array(let a): errors += validateArray(schema, a, path)
        case .string(let s): errors += validateString(schema, s, here)
        case .int, .double: errors += validateNumber(schema, value, here)
        default: break
        }
        if case .array(let subs)? = schema["allOf"] {
            for s in subs { errors += validate(value, against: s, path: path) }
        }
        if case .array(let subs)? = schema["anyOf"], !subs.contains(where: { validate(value, against: $0, path: path).isEmpty }) {
            errors.append("\(here): matches none of the allowed shapes (anyOf)")
        }
        if case .array(let subs)? = schema["oneOf"] {
            let n = subs.filter { validate(value, against: $0, path: path).isEmpty }.count
            if n != 1 { errors.append("\(here): must match exactly one shape (oneOf), matches \(n)") }
        }
        if let not = schema["not"], validate(value, against: not, path: path).isEmpty {
            errors.append("\(here): matches a disallowed shape (not)")
        }
        return errors
    }

    private static func validateObject(_ schema: JSONValue, _ members: [(String, JSONValue)], _ path: String) -> [String] {
        let here = path.isEmpty ? "/" : path
        var errors: [String] = []
        let keys = Set(members.map(\.0))
        if case .array(let required)? = schema["required"] {
            for case .string(let k) in required where !keys.contains(k) {
                errors.append("\(here): missing required property \(k)")
            }
        }
        var props: [String: JSONValue] = [:]
        if case .object(let p)? = schema["properties"] {
            for (k, v) in p { props[k] = v }
        }
        for (k, v) in members {
            if let ps = props[k] {
                errors += validate(v, against: ps, path: "\(path)/\(k)")
            } else if let ap = schema["additionalProperties"] {
                if ap == .bool(false) {
                    errors.append("\(here): property \(k) is not allowed")
                } else {
                    errors += validate(v, against: ap, path: "\(path)/\(k)")
                }
            }
        }
        if case .int(let n)? = schema["minProperties"], keys.count < n {
            errors.append("\(here): needs at least \(n) properties")
        }
        if case .int(let n)? = schema["maxProperties"], keys.count > n {
            errors.append("\(here): allows at most \(n) properties")
        }
        return errors
    }

    private static func validateArray(_ schema: JSONValue, _ items: [JSONValue], _ path: String) -> [String] {
        let here = path.isEmpty ? "/" : path
        var errors: [String] = []
        if case .int(let n)? = schema["minItems"], items.count < n {
            errors.append("\(here): needs at least \(n) items, has \(items.count)")
        }
        if case .int(let n)? = schema["maxItems"], items.count > n {
            errors.append("\(here): allows at most \(n) items, has \(items.count)")
        }
        if schema["uniqueItems"] == .bool(true) {
            outer: for i in items.indices {
                for j in items.indices where j > i && equal(items[i], items[j]) {
                    errors.append("\(here): items must be unique")
                    break outer
                }
            }
        }
        if let itemSchema = schema["items"] {
            for (i, v) in items.enumerated() { errors += validate(v, against: itemSchema, path: "\(path)/\(i)") }
        }
        return errors
    }

    private static func validateString(_ schema: JSONValue, _ s: String, _ here: String) -> [String] {
        var errors: [String] = []
        let n = s.unicodeScalars.count
        if case .int(let lo)? = schema["minLength"], n < lo { errors.append("\(here): shorter than \(lo) characters") }
        if case .int(let hi)? = schema["maxLength"], n > hi { errors.append("\(here): longer than \(hi) characters") }
        if case .string(let p)? = schema["pattern"], !RE2.matches(p, s) { errors.append("\(here): does not match pattern \(p)") }
        return errors
    }

    private static func validateNumber(_ schema: JSONValue, _ value: JSONValue, _ here: String) -> [String] {
        var errors: [String] = []
        func compare(_ bound: JSONValue?) -> (bound: JSONValue, order: Int)? {
            guard let bound, let o = order(value, bound) else { return nil }
            return (bound, o)
        }
        if let (b, o) = compare(schema["minimum"]), o < 0 { errors.append("\(here): below minimum \(b.jsonText)") }
        if let (b, o) = compare(schema["maximum"]), o > 0 { errors.append("\(here): above maximum \(b.jsonText)") }
        if let (b, o) = compare(schema["exclusiveMinimum"]), o <= 0 { errors.append("\(here): must be above \(b.jsonText)") }
        if let (b, o) = compare(schema["exclusiveMaximum"]), o >= 0 { errors.append("\(here): must be below \(b.jsonText)") }
        if let m = schema["multipleOf"], !isMultiple(value, of: m) { errors.append("\(here): not a multiple of \(m.jsonText)") }
        return errors
    }

    /// -1, 0 or 1 as `a` is below, equal to or above `b`; integers compare exactly.
    static func order(_ a: JSONValue, _ b: JSONValue) -> Int? {
        if case .int(let x) = a, case .int(let y) = b { return x < y ? -1 : x == y ? 0 : 1 }
        guard let x = number(a), let y = number(b) else { return nil }
        return x < y ? -1 : x == y ? 0 : 1
    }

    static func isMultiple(_ value: JSONValue, of m: JSONValue) -> Bool {
        if case .int(let x) = value, case .int(let y) = m, y > 0 { return x % y == 0 }
        guard let x = number(value), let y = number(m), y > 0 else { return true }
        let q = x / y
        return q.isFinite && abs(q - q.rounded()) <= 1e-9 * Swift.max(1, abs(q))
    }

    static func number(_ v: JSONValue) -> Double? {
        switch v {
        case .int(let i): Double(i)
        case .double(let d): d
        default: nil
        }
    }

    static func typeMatches(_ type: String, _ v: JSONValue) -> Bool {
        switch (type, v) {
        case ("object", .object), ("array", .array), ("string", .string), ("boolean", .bool), ("null", .null): true
        case ("integer", .int): true
        case ("integer", .double(let d)): d.isFinite && d.rounded() == d
        case ("number", .int): true
        case ("number", .double(let d)): d.isFinite
        default: false
        }
    }

    static func typeName(_ v: JSONValue) -> String {
        switch v {
        case .null: "null"
        case .bool: "boolean"
        case .int: "integer"
        case .double(let d): d.isFinite && d.rounded() == d ? "integer" : "number"
        case .string: "string"
        case .array: "array"
        case .object: "object"
        }
    }

    /// JSON equality: numbers by value (`1` equals `1.0`), objects as maps.
    static func equal(_ a: JSONValue, _ b: JSONValue) -> Bool {
        switch (a, b) {
        case (.int, .int), (.int, .double), (.double, .int), (.double, .double): return order(a, b) == 0
        case (.array(let x), .array(let y)): return x.count == y.count && zip(x, y).allSatisfy(equal)
        case (.object(let x), .object(let y)):
            let dx = Dictionary(x, uniquingKeysWith: { a, _ in a })
            let dy = Dictionary(y, uniquingKeysWith: { a, _ in a })
            return dx.count == dy.count && dx.allSatisfy { k, v in dy[k].map { equal(v, $0) } ?? false }
        default: return a == b
        }
    }
}
