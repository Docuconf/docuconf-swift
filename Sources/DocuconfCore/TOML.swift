import Foundation

/// A TOML 1.0 reader, Foundation only, for `toml` config files and overlays (SPEC §4.6, §4.7). It returns the
/// document as a ``JSONValue``: tables as objects (keys in the order written), arrays, strings, integers, floats
/// and booleans. Dates and times, which JSON has no type for, are strings as written.
///
/// ```swift
/// let doc = try TOML.parse("name = \"orders\"\n[limits]\nburst = 10\n")   // {"name": "orders", "limits": {"burst": 10}}
/// ```
public enum TOML {
    /// Parses a TOML document. Throws ``MalformedFileError`` with the line and what is wrong, never the content.
    public static func parse(_ text: String) throws -> JSONValue {
        var p = Parser(Array(text.unicodeScalars))
        return try p.document()
    }

    /// Parses UTF-8 TOML (a leading byte-order mark is skipped).
    public static func parse(_ data: Data) throws -> JSONValue {
        var bytes = data
        if bytes.starts(with: [0xEF, 0xBB, 0xBF]) { bytes = bytes.dropFirst(3) }
        guard let text = String(data: bytes, encoding: .utf8) else { throw MalformedFileError("not UTF-8") }
        return try parse(text)
    }

    /// A table under construction. Keys keep their order; `defined` tracks tables written with a header or a
    /// dotted key, which TOML does not allow to be defined twice.
    final class Table {
        var keys: [String] = []
        var values: [String: Node] = [:]
        var explicit = false
        var inline = false
        var fromDotted = false

        func json() -> JSONValue {
            .object(keys.map { ($0, values[$0]!.json()) })
        }
    }

    enum Node {
        case value(JSONValue)
        case table(Table)
        /// An array of tables (`[[name]]`).
        case tables([Table])
        /// A static array, which may hold inline tables.
        case array([Node])

        func json() -> JSONValue {
            switch self {
            case .value(let v): v
            case .table(let t): t.json()
            case .tables(let ts): .array(ts.map { $0.json() })
            case .array(let a): .array(a.map { $0.json() })
            }
        }
    }

    struct Parser {
        let s: [Unicode.Scalar]
        var i = 0
        var line = 1

        init(_ s: [Unicode.Scalar]) { self.s = s }

        func fail(_ what: String) -> MalformedFileError { MalformedFileError("line \(line): \(what)") }

        var peek: Unicode.Scalar? { i < s.count ? s[i] : nil }
        func peek(_ n: Int) -> Unicode.Scalar? { i + n < s.count ? s[i + n] : nil }

        mutating func advance() {
            if s[i] == "\n" { line += 1 }
            i += 1
        }

        mutating func skipSpaces() {
            while let c = peek, c == " " || c == "\t" { i += 1 }
        }

        mutating func skipComment() throws {
            guard peek == "#" else { return }
            while let c = peek, c != "\n" {
                if c == "\r" && peek(1) == "\n" { break }
                if Self.isControl(c) && c != "\t" { throw fail("control character in a comment") }
                i += 1
            }
        }

        /// Skips to the end of the line, which may hold only spaces and a comment.
        mutating func endOfLine() throws {
            skipSpaces()
            try skipComment()
            if peek == nil { return }
            if peek == "\r" && peek(1) == "\n" { i += 1 }
            guard peek == "\n" else { throw fail("expected the end of the line") }
            advance()
        }

        /// Skips blank lines, comments and whitespace, newlines included.
        mutating func skipTrivia() throws {
            while true {
                skipSpaces()
                try skipComment()
                if peek == "\n" { advance(); continue }
                if peek == "\r" && peek(1) == "\n" { i += 1; advance(); continue }
                return
            }
        }

        static func isControl(_ c: Unicode.Scalar) -> Bool { c.value < 0x20 || c.value == 0x7F }

        mutating func document() throws -> JSONValue {
            let root = Table()
            var current = root
            while true {
                try skipTrivia()
                guard let c = peek else { break }
                if c == "[" {
                    if peek(1) == "[" {
                        i += 2
                        skipSpaces()
                        let key = try keyPath()
                        skipSpaces()
                        guard peek == "]", peek(1) == "]" else { throw fail("expected ]] after an array of tables") }
                        i += 2
                        current = try appendTable(root, key)
                    } else {
                        i += 1
                        skipSpaces()
                        let key = try keyPath()
                        skipSpaces()
                        guard peek == "]" else { throw fail("expected ] after a table name") }
                        i += 1
                        current = try defineTable(root, key)
                    }
                    try endOfLine()
                } else {
                    try keyValue(into: current)
                    try endOfLine()
                }
            }
            return root.json()
        }

        // MARK: Keys

        mutating func keyPath() throws -> [String] {
            var parts = [try simpleKey()]
            while true {
                skipSpaces()
                guard peek == "." else { return parts }
                i += 1
                skipSpaces()
                parts.append(try simpleKey())
            }
        }

        mutating func simpleKey() throws -> String {
            switch peek {
            case "\""?:
                if peek(1) == "\"" && peek(2) == "\"" { throw fail("a key cannot be a multi-line string") }
                return try basicString()
            case "'"?:
                if peek(1) == "'" && peek(2) == "'" { throw fail("a key cannot be a multi-line string") }
                return try literalString()
            default:
                var out = ""
                while let c = peek, Self.isBareKey(c) {
                    out.unicodeScalars.append(c)
                    i += 1
                }
                guard !out.isEmpty else { throw fail("expected a key") }
                return out
            }
        }

        static func isBareKey(_ c: Unicode.Scalar) -> Bool {
            ("a"..."z").contains(c) || ("A"..."Z").contains(c) || ("0"..."9").contains(c) || c == "_" || c == "-"
        }

        // MARK: Tables

        /// Walks `path` from `root`, creating implicit tables, and returns the table it names.
        func walk(_ root: Table, _ path: ArraySlice<String>, dotted: Bool) throws -> Table {
            var t = root
            for k in path {
                switch t.values[k] {
                case nil:
                    let n = Table()
                    n.fromDotted = dotted
                    t.keys.append(k)
                    t.values[k] = .table(n)
                    t = n
                case .table(let n)?:
                    if n.inline { throw fail("cannot extend the inline table \(k)") }
                    if dotted && n.explicit && !n.fromDotted { throw fail("cannot extend the table \(k) with a dotted key") }
                    t = n
                case .tables(let ts)?:
                    if dotted { throw fail("cannot extend the array of tables \(k) with a dotted key") }
                    t = ts[ts.count - 1]
                default:
                    throw fail("\(k) is already a value, not a table")
                }
            }
            return t
        }

        func defineTable(_ root: Table, _ path: [String]) throws -> Table {
            let parent = try walk(root, path.dropLast(), dotted: false)
            let k = path[path.count - 1]
            switch parent.values[k] {
            case nil:
                let t = Table()
                t.explicit = true
                parent.keys.append(k)
                parent.values[k] = .table(t)
                return t
            case .table(let t)?:
                if t.explicit || t.inline || t.fromDotted { throw fail("table \(path.joined(separator: ".")) is defined twice") }
                t.explicit = true
                return t
            default:
                throw fail("\(path.joined(separator: ".")) is already a value, not a table")
            }
        }

        func appendTable(_ root: Table, _ path: [String]) throws -> Table {
            let parent = try walk(root, path.dropLast(), dotted: false)
            let k = path[path.count - 1]
            let t = Table()
            t.explicit = true
            switch parent.values[k] {
            case nil:
                parent.keys.append(k)
                parent.values[k] = .tables([t])
            case .tables(let ts)?:
                parent.values[k] = .tables(ts + [t])
            default:
                throw fail("\(path.joined(separator: ".")) is not an array of tables")
            }
            return t
        }

        mutating func keyValue(into table: Table) throws {
            let path = try keyPath()
            skipSpaces()
            guard peek == "=" else { throw fail("expected = after a key") }
            i += 1
            skipSpaces()
            let v = try value()
            let parent = try walk(table, path.dropLast(), dotted: true)
            let k = path[path.count - 1]
            guard parent.values[k] == nil else { throw fail("key \(path.joined(separator: ".")) is defined twice") }
            parent.keys.append(k)
            parent.values[k] = v
        }

        // MARK: Values

        mutating func value() throws -> Node {
            guard let c = peek else { throw fail("expected a value") }
            switch c {
            case "\"":
                if peek(1) == "\"" && peek(2) == "\"" { return .value(.string(try multilineBasicString())) }
                return .value(.string(try basicString()))
            case "'":
                if peek(1) == "'" && peek(2) == "'" { return .value(.string(try multilineLiteralString())) }
                return .value(.string(try literalString()))
            case "[":
                return try array()
            case "{":
                return try inlineTable()
            default:
                return .value(try scalar())
            }
        }

        mutating func array() throws -> Node {
            i += 1
            var items: [Node] = []
            while true {
                try skipTrivia()
                if peek == "]" { i += 1; return .array(items) }
                items.append(try value())
                try skipTrivia()
                if peek == "," { i += 1; continue }
                guard peek == "]" else { throw fail("expected , or ] in an array") }
                i += 1
                return .array(items)
            }
        }

        mutating func inlineTable() throws -> Node {
            i += 1
            let t = Table()
            skipSpaces()
            if peek == "}" {
                i += 1
                t.inline = true
                return .table(t)
            }
            while true {
                skipSpaces()
                try keyValue(into: t)
                skipSpaces()
                if peek == "," { i += 1; continue }
                guard peek == "}" else { throw fail("expected , or } in an inline table") }
                i += 1
                break
            }
            markInline(t)
            return .table(t)
        }

        func markInline(_ t: Table) {
            t.inline = true
            for case .table(let sub) in t.values.values { markInline(sub) }
        }

        /// A bare value: a boolean, number or date-time, up to the next delimiter.
        mutating func scalar() throws -> JSONValue {
            var token = ""
            while let c = peek, !(c == "," || c == "]" || c == "}" || c == "#" || c == "\n" || c == "\r") {
                if c == " " || c == "\t" {
                    // A space separates a date from a time (`1979-05-27 07:32:00`); anything else ends the value.
                    if Self.isDate(token), let d = peek(1), ("0"..."9").contains(d) {
                        token.unicodeScalars.append("T")
                        i += 1
                        continue
                    }
                    break
                }
                token.unicodeScalars.append(c)
                i += 1
            }
            if token == "true" { return .bool(true) }
            if token == "false" { return .bool(false) }
            if let v = Self.number(token) { return v }
            if Self.isDateTime(token) { return .string(token) }
            throw fail(token.isEmpty ? "expected a value" : "a value that is not a string, number, boolean or date (strings need quotes)")
        }

        static func isDate(_ t: String) -> Bool {
            let b = Array(t.utf8)
            guard b.count == 10, b[4] == UInt8(ascii: "-"), b[7] == UInt8(ascii: "-") else { return false }
            return b.enumerated().allSatisfy { $0.offset == 4 || $0.offset == 7 || (0x30...0x39).contains($0.element) }
        }

        static func isDateTime(_ t: String) -> Bool {
            let pattern = #"^(\d{4}-\d{2}-\d{2}([Tt]\d{2}:\d{2}(:\d{2}(\.\d+)?)?([Zz]|[+-]\d{2}:\d{2})?)?|\d{2}:\d{2}(:\d{2}(\.\d+)?)?)$"#
            return t.range(of: pattern, options: .regularExpression) != nil
        }

        static func number(_ t: String) -> JSONValue? {
            switch t {
            case "inf", "+inf", "-inf", "nan", "+nan", "-nan":
                // JSON has no infinities or NaN; such a value cannot be checked against a schema.
                return nil
            default: break
            }
            let b = Array(t.utf8)
            guard !b.isEmpty else { return nil }
            func validUnderscores(_ digits: ArraySlice<UInt8>, _ isDigit: (UInt8) -> Bool) -> Bool {
                guard let f = digits.first, let l = digits.last, isDigit(f), isDigit(l) else { return false }
                var prevUnderscore = false
                for c in digits {
                    if c == UInt8(ascii: "_") {
                        if prevUnderscore { return false }
                        prevUnderscore = true
                    } else {
                        guard isDigit(c) else { return false }
                        prevUnderscore = false
                    }
                }
                return true
            }
            let dec: (UInt8) -> Bool = { (0x30...0x39).contains($0) }
            // Prefixed integers: 0x, 0o, 0b (no sign).
            if b.count > 2, b[0] == UInt8(ascii: "0") {
                let radix: Int?
                let isDigit: (UInt8) -> Bool
                switch b[1] {
                case UInt8(ascii: "x"): radix = 16; isDigit = { dec($0) || (0x61...0x66).contains($0) || (0x41...0x46).contains($0) }
                case UInt8(ascii: "o"): radix = 8; isDigit = { (0x30...0x37).contains($0) }
                case UInt8(ascii: "b"): radix = 2; isDigit = { $0 == 0x30 || $0 == 0x31 }
                default: radix = nil; isDigit = dec
                }
                if let radix {
                    let digits = b[2...]
                    guard validUnderscores(digits, isDigit) else { return nil }
                    let clean = String(decoding: digits.filter { $0 != UInt8(ascii: "_") }, as: UTF8.self)
                    return Int(clean, radix: radix).map(JSONValue.int)
                }
            }
            var body = b[...]
            if body.first == UInt8(ascii: "+") || body.first == UInt8(ascii: "-") { body = body.dropFirst() }
            // Split into integer part, fraction and exponent.
            let intEnd = body.firstIndex { $0 == UInt8(ascii: ".") || $0 == UInt8(ascii: "e") || $0 == UInt8(ascii: "E") } ?? body.endIndex
            let intPart = body[body.startIndex..<intEnd]
            guard validUnderscores(intPart, dec) else { return nil }
            if intPart.count > 1 && intPart.first == UInt8(ascii: "0") { return nil }  // no leading zeros
            let clean = String(decoding: b.filter { $0 != UInt8(ascii: "_") }, as: UTF8.self)
            if intEnd == body.endIndex {
                return Int(clean).map(JSONValue.int)
            }
            var rest = body[intEnd...]
            if rest.first == UInt8(ascii: ".") {
                rest = rest.dropFirst()
                let fracEnd = rest.firstIndex { $0 == UInt8(ascii: "e") || $0 == UInt8(ascii: "E") } ?? rest.endIndex
                guard validUnderscores(rest[rest.startIndex..<fracEnd], dec) else { return nil }
                rest = rest[fracEnd...]
            }
            if let e = rest.first, e == UInt8(ascii: "e") || e == UInt8(ascii: "E") {
                rest = rest.dropFirst()
                if rest.first == UInt8(ascii: "+") || rest.first == UInt8(ascii: "-") { rest = rest.dropFirst() }
                guard validUnderscores(rest, dec) else { return nil }
            } else if !rest.isEmpty {
                return nil
            }
            guard let d = Double(clean), d.isFinite else { return nil }
            return .double(d)
        }

        // MARK: Strings

        mutating func basicString() throws -> String {
            i += 1
            var out = ""
            while true {
                guard let c = peek else { throw fail("unterminated string") }
                if c == "\"" { i += 1; return out }
                if c == "\n" || c == "\r" { throw fail("newline in a single-line string") }
                if c == "\\" {
                    i += 1
                    out.unicodeScalars.append(try escape())
                    continue
                }
                if Self.isControl(c) && c != "\t" { throw fail("control character in a string") }
                out.unicodeScalars.append(c)
                i += 1
            }
        }

        mutating func escape() throws -> Unicode.Scalar {
            guard let c = peek else { throw fail("unterminated escape") }
            i += 1
            switch c {
            case "b": return "\u{08}"
            case "t": return "\t"
            case "n": return "\n"
            case "f": return "\u{0C}"
            case "r": return "\r"
            case "\"": return "\""
            case "\\": return "\\"
            case "u", "U":
                let n = c == "u" ? 4 : 8
                guard i + n <= s.count else { throw fail("short unicode escape") }
                var hex = ""
                for k in 0..<n { hex.unicodeScalars.append(s[i + k]) }
                i += n
                guard let v = UInt32(hex, radix: 16), let scalar = Unicode.Scalar(v) else { throw fail("invalid unicode escape") }
                return scalar
            default:
                throw fail("invalid escape \\\(c)")
            }
        }

        mutating func multilineBasicString() throws -> String {
            i += 3
            if peek == "\n" { advance() } else if peek == "\r" && peek(1) == "\n" { i += 1; advance() }
            var out = ""
            while true {
                guard let c = peek else { throw fail("unterminated multi-line string") }
                if c == "\"" && peek(1) == "\"" && peek(2) == "\"" {
                    // Up to two quotes may end the content just before the closing delimiter.
                    var extra = 0
                    while peek(3 + extra) == "\"" && extra < 2 { extra += 1 }
                    for _ in 0..<extra { out.unicodeScalars.append("\"") }
                    i += 3 + extra
                    return out
                }
                if c == "\\" {
                    // A line-ending backslash trims the newline and the whitespace after it.
                    var j = i + 1
                    while j < s.count, s[j] == " " || s[j] == "\t" { j += 1 }
                    if j < s.count, s[j] == "\n" || (s[j] == "\r" && j + 1 < s.count && s[j + 1] == "\n") {
                        i = j
                        while let w = peek, w == " " || w == "\t" || w == "\n" || w == "\r" { advance() }
                        continue
                    }
                    i += 1
                    out.unicodeScalars.append(try escape())
                    continue
                }
                if Self.isControl(c) && c != "\t" && c != "\n" && !(c == "\r" && peek(1) == "\n") {
                    throw fail("control character in a string")
                }
                out.unicodeScalars.append(c)
                advance()
            }
        }

        mutating func literalString() throws -> String {
            i += 1
            var out = ""
            while true {
                guard let c = peek else { throw fail("unterminated string") }
                if c == "'" { i += 1; return out }
                if c == "\n" || c == "\r" { throw fail("newline in a single-line string") }
                if Self.isControl(c) && c != "\t" { throw fail("control character in a string") }
                out.unicodeScalars.append(c)
                i += 1
            }
        }

        mutating func multilineLiteralString() throws -> String {
            i += 3
            if peek == "\n" { advance() } else if peek == "\r" && peek(1) == "\n" { i += 1; advance() }
            var out = ""
            while true {
                guard let c = peek else { throw fail("unterminated multi-line string") }
                if c == "'" && peek(1) == "'" && peek(2) == "'" {
                    var extra = 0
                    while peek(3 + extra) == "'" && extra < 2 { extra += 1 }
                    for _ in 0..<extra { out.unicodeScalars.append("'") }
                    i += 3 + extra
                    return out
                }
                if Self.isControl(c) && c != "\t" && c != "\n" && !(c == "\r" && peek(1) == "\n") {
                    throw fail("control character in a string")
                }
                out.unicodeScalars.append(c)
                advance()
            }
        }
    }
}
