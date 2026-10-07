import Foundation

/// A variable's value after parsing and before constraint checks.
public enum ParsedValue: Sendable, Hashable {
    case string(String)
    case int(Int)
    case double(Double)
    case bool(Bool)
    case duration(Duration)
    case url(String)
    case enumCase(String)
    case stringList([String])
    case intList([Int])
    /// A `json` variable's raw text. It is checked by decoding it into the app's type.
    case json(String)

    /// The value as JSON, as the conformance suite compares it (SPEC §12): durations in canonical Go form,
    /// lists as arrays, a `json` value as the document it holds.
    public var jsonValue: JSONValue {
        switch self {
        case .string(let s), .url(let s), .enumCase(let s): .string(s)
        case .int(let i): .int(i)
        case .double(let d): .double(d)
        case .bool(let b): .bool(b)
        case .duration(let d): .string(d < .zero ? "-" + GoDuration.format(.zero - d) : GoDuration.format(d))
        case .stringList(let l): .array(l.map(JSONValue.string))
        case .intList(let l): .array(l.map(JSONValue.int))
        case .json(let text): (try? JSONDecoder().decode(JSONValue.self, from: Data(text.utf8))) ?? .string(text)
        }
    }
}

extension VarSpec {
    /// Parses a variable from an environment in its contract's encodings (SPEC §5): the parser of
    /// contract-first mode (``ContractDocument``). An `indexed` list reads `NAME__0`, `NAME__1`, ... up to the
    /// first missing index. The server SDK lets swift-configuration parse instead, then shares ``resolve(raw:parse:)``
    /// and ``check(_:)`` with this path.
    ///
    /// Returns the raw value (the first item for an `indexed` list), used for the injector-reference check, and the
    /// parse result: `nil` for an unset value, as an empty string is for every type but `string`.
    public func parse(environment env: [String: String]) -> (raw: String?, parsed: Result<ParsedValue, Violation>?) {
        guard type == .list, listWire == .indexed else {
            let raw = env[name]
            return (raw, raw.flatMap { parse(wire: $0) })
        }
        var items: [String] = []
        while let item = env["\(name)__\(items.count)"] { items.append(item) }
        if items.isEmpty { return (nil, nil) }
        return (items[0], parseItems(items, raw: items.joined(separator: ",")))
    }

    /// Parses one wire string in the contract's encoding. Returns `nil` for an unset value: an empty string is
    /// unset for every type but `string`. An `indexed` list has no single wire string; use ``parse(environment:)``.
    public func parse(wire: String) -> Result<ParsedValue, Violation>? {
        if wire.isEmpty && type != .string { return nil }
        switch type {
        case .string:
            return .success(.string(wire))
        case .int:
            switch Self.parseInt(wire) {
            case .success(let i): return .success(.int(i))
            case .failure(let e): return .failure(intViolation(e, wire))
            }
        case .float:
            guard let d = Self.parseDouble(wire) else { return .failure(invalid("is not a finite decimal number", wire)) }
            return .success(.double(d))
        case .bool:
            switch wire.lowercased() {
            case "true": return .success(.bool(true))
            case "false": return .success(.bool(false))
            default: return .failure(invalid("is not true or false", wire))
            }
        case .duration:
            guard let d = durationWire.parse(wire) else {
                return .failure(invalid("is not a duration in the \(durationWire.rawValue) encoding", wire))
            }
            return .success(.duration(d))
        case .url:
            return .success(.url(wire))
        case .enum:
            return .success(.enumCase(wire))
        case .list:
            switch listWire {
            case .csv, .indexed:
                return parseItems(wire.components(separatedBy: separator.isEmpty ? "," : separator), raw: wire)
            case .json:
                guard case .array(let elements)? = try? JSONDecoder().decode(JSONValue.self, from: Data(wire.utf8)) else {
                    return .failure(invalid("is not a JSON array", wire))
                }
                if items == .int {
                    var ints: [Int] = []
                    for (n, e) in elements.enumerated() {
                        switch e {
                        case .int(let i): ints.append(i)
                        case .double(let d) where d.rounded() == d && d.magnitude >= 0x1p63:
                            return .failure(Violation(.outOfRange, name, "item \(n) is outside the 64-bit integer range" + shown(wire)))
                        default: return .failure(invalid("item \(n) is not an integer", wire))
                        }
                    }
                    return .success(.intList(ints))
                }
                var strings: [String] = []
                for (n, e) in elements.enumerated() {
                    guard case .string(let s) = e else { return .failure(invalid("item \(n) is not a string", wire)) }
                    strings.append(s)
                }
                return .success(.stringList(strings))
            }
        case .json:
            guard (try? JSONDecoder().decode(JSONValue.self, from: Data(wire.utf8))) != nil else {
                return .failure(invalid("is not valid JSON", wire))
            }
            return .success(.json(wire))
        }
    }

    /// A list from its items as text.
    package func parseItems(_ parts: [String], raw: String) -> Result<ParsedValue, Violation> {
        guard items == .int else { return .success(.stringList(parts)) }
        var ints: [Int] = []
        for (n, p) in parts.enumerated() {
            switch Self.parseInt(p) {
            case .success(let i): ints.append(i)
            case .failure(.outOfRange):
                return .failure(Violation(.outOfRange, name, "item \(n) is outside the 64-bit integer range" + shown(raw)))
            case .failure(.notAnInteger):
                return .failure(invalid("item \(n) is not a base-10 integer", raw))
            }
        }
        return .success(.intList(ints))
    }

    /// Why a string is not an `int`.
    public enum IntParseError: Error, Sendable {
        /// Not a base-10 integer: `invalid_type`.
        case notAnInteger
        /// An integer outside the 64-bit signed range: `out_of_range` (SPEC §5).
        case outOfRange
    }

    /// Parses a base-10 integer with an optional sign.
    public static func parseInt(_ s: String) -> Result<Int, IntParseError> {
        let digits = s.first == "-" || s.first == "+" ? s.dropFirst() : Substring(s)
        guard !digits.isEmpty, digits.allSatisfy({ $0.isASCII && $0.isNumber }) else { return .failure(.notAnInteger) }
        guard let i = Int(s) else { return .failure(.outOfRange) }
        return .success(i)
    }

    /// The violation for a value that is not an `int`.
    public func intViolation(_ error: IntParseError, _ raw: String) -> Violation {
        switch error {
        case .notAnInteger: invalid("is not a base-10 integer", raw)
        case .outOfRange: Violation(.outOfRange, name, "is outside the 64-bit integer range" + shown(raw))
        }
    }

    /// A decimal number, independent of the locale. `NaN`, infinities and hexadecimal floats are rejected.
    static func parseDouble(_ s: String) -> Double? {
        var rest = Substring(s)
        if rest.first == "-" || rest.first == "+" { rest = rest.dropFirst() }
        let mantissa = rest.prefix { ($0.isASCII && $0.isNumber) || $0 == "." }
        guard mantissa.contains(where: \.isNumber), mantissa.filter({ $0 == "." }).count <= 1 else { return nil }
        rest = rest.dropFirst(mantissa.count)
        if let e = rest.first, e == "e" || e == "E" {
            rest = rest.dropFirst()
            if rest.first == "-" || rest.first == "+" { rest = rest.dropFirst() }
            guard !rest.isEmpty, rest.allSatisfy({ $0.isASCII && $0.isNumber }) else { return nil }
            rest = ""
        }
        guard rest.isEmpty, let d = Double(s), d.isFinite else { return nil }
        return d
    }

    /// Reads one variable: the steps shared by boot loading and contract-first mode, so both apply the same rules.
    ///
    /// 1. A secret that still holds an injector reference is `invalid_type` (SPEC §4.5.1).
    /// 2. `parse` returns `nil` when the variable is unset: a required one is `missing_required`, an optional one
    ///    resolves to `nil` (its default applies).
    /// 3. A parsed value is checked against every constraint.
    ///
    /// - Returns: the checked value, `nil` when unset, or every violation found.
    public func resolve(raw: String?, parse: () -> Result<ParsedValue, Violation>?) -> Result<ParsedValue?, ConfigurationError> {
        if secret, let raw, let v = InjectorReference.violation(for: name, value: raw) {
            return .failure(ConfigurationError(violations: [v]))
        }
        switch parse() {
        case nil:
            if required { return .failure(ConfigurationError(violations: [Violation(.missingRequired, name, "is required but not set")])) }
            return .success(nil)
        case .failure(let v):
            return .failure(ConfigurationError(violations: [v]))
        case .success(let value):
            let violations = check(value)
            return violations.isEmpty ? .success(value) : .failure(ConfigurationError(violations: violations))
        }
    }

    /// The value as it may appear in a message: never for a secret.
    func shown(_ raw: String) -> String {
        secret ? "" : " (got \(JSONValue.quote(raw)))"
    }

    func invalid(_ what: String, _ raw: String) -> Violation {
        Violation(.invalidType, name, what + shown(raw))
    }

    /// Checks a parsed value against the variable's constraints, returning every violation.
    public func check(_ value: ParsedValue) -> [Violation] {
        var out: [Violation] = []
        func add(_ code: ViolationCode, _ message: String) { out.append(Violation(code, name, message)) }

        switch value {
        case .string(let s):
            let n = s.unicodeScalars.count
            if let minLength, n < minLength { add(.outOfRange, "is shorter than \(minLength) characters" + shown(s)) }
            if let maxLength, n > maxLength { add(.outOfRange, "is longer than \(maxLength) characters" + shown(s)) }
            if let pattern, !RE2.matches(pattern, s) { add(.patternMismatch, "does not match \(pattern)" + shown(s)) }
        case .int(let i):
            if case .int(let lo)? = min, i < lo { add(.outOfRange, "is below min \(lo)" + shown(String(i))) }
            if case .int(let hi)? = max, i > hi { add(.outOfRange, "is above max \(hi)" + shown(String(i))) }
        case .double(let d):
            if !d.isFinite { add(.invalidType, "is not a finite number") }
            if let lo = min?.asDouble, d < lo { add(.outOfRange, "is below min \(min!)" + shown(JSONValue.format(d))) }
            if let hi = max?.asDouble, d > hi { add(.outOfRange, "is above max \(max!)" + shown(JSONValue.format(d))) }
        case .bool:
            break
        case .duration(let d):
            let shownValue = shown(GoDuration.format(Swift.max(d, .zero)))
            if d < .zero { add(.outOfRange, "is negative") }
            if let minDuration, d < minDuration {
                add(.outOfRange, "is below min \(GoDuration.format(minDuration))" + shownValue)
            }
            if let maxDuration, d > maxDuration {
                add(.outOfRange, "is above max \(GoDuration.format(maxDuration))" + shownValue)
            }
        case .url(let s):
            if let scheme = Self.urlScheme(s) {
                if let schemes, !schemes.contains(scheme) {
                    add(.invalidScheme, "scheme \(secret ? "" : "\(scheme) ")is not one of \(schemes.joined(separator: ", "))")
                }
            } else {
                add(.invalidType, "is not a URL of the form scheme://..." + shown(s))
            }
        case .enumCase(let s):
            if let values, !values.contains(s) {
                add(.notInEnum, "is not one of \(values.joined(separator: ", "))" + shown(s))
            }
        case .stringList(let l):
            out += checkCount(l.count)
        case .intList(let l):
            out += checkCount(l.count)
            if let (i, item) = l.enumerated().first(where: { $0.element < itemMin ?? .min || $0.element > itemMax ?? .max }) {
                let bound = item < itemMin ?? .min ? "below itemMin \(itemMin!)" : "above itemMax \(itemMax!)"
                add(.outOfRange, "item \(i) is \(bound)" + shown(String(item)))
            }
        case .json:
            break
        }
        return out
    }

    private func checkCount(_ n: Int) -> [Violation] {
        var out: [Violation] = []
        if let minItems, n < minItems { out.append(Violation(.tooFewItems, name, "has \(n) items; at least \(minItems) required")) }
        if let maxItems, n > maxItems { out.append(Violation(.tooManyItems, name, "has \(n) items; at most \(maxItems) allowed")) }
        return out
    }

    /// The scheme of a URL in the meta-schema's sense (`^[a-zA-Z][a-zA-Z0-9+.-]*://[^\s]+$`), or `nil`.
    public static func urlScheme(_ s: String) -> String? {
        guard let sep = s.range(of: "://") else { return nil }
        let scheme = s[..<sep.lowerBound]
        let rest = s[sep.upperBound...]
        guard let first = scheme.unicodeScalars.first, ("a"..."z").contains(first) || ("A"..."Z").contains(first),
            scheme.unicodeScalars.allSatisfy({ $0.isASCII && (CharacterSet.alphanumerics.contains($0) || "+.-".unicodeScalars.contains($0)) }),
            !rest.isEmpty, !rest.unicodeScalars.contains(where: { CharacterSet.whitespacesAndNewlines.contains($0) })
        else { return nil }
        return String(scheme)
    }
}
