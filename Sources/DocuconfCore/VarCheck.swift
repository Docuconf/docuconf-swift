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
}

extension VarSpec {
    /// Parses a wire string (SPEC §5) without a host library: used for contract-first checks and tests.
    /// The server SDK lets swift-configuration parse numbers, booleans and lists, then calls ``check(_:)``.
    ///
    /// Returns `nil` for an unset value: an empty string is unset for every type but `string`.
    public func parse(wire: String) -> Result<ParsedValue, Violation>? {
        if wire.isEmpty && type != .string { return nil }
        switch type {
        case .string:
            return .success(.string(wire))
        case .int:
            guard let i = Self.parseInt(wire) else { return .failure(invalid("is not a base-10 integer", wire)) }
            return .success(.int(i))
        case .float:
            guard let d = Self.parseDouble(wire) else { return .failure(invalid("is not a finite number", wire)) }
            return .success(.double(d))
        case .bool:
            switch wire.lowercased() {
            case "true": return .success(.bool(true))
            case "false": return .success(.bool(false))
            default: return .failure(invalid("is not true or false", wire))
            }
        case .duration:
            guard let d = Self.parseDouble(wire), d >= 0 else {
                return .failure(invalid("is not a non-negative number of seconds", wire))
            }
            return .success(.duration(.milliseconds(Int64((d * 1000).rounded()))))
        case .url:
            return .success(.url(wire))
        case .enum:
            return .success(.enumCase(wire))
        case .list:
            let parts = wire.split(separator: ",", omittingEmptySubsequences: false).map(String.init)
            if items == .int {
                var ints: [Int] = []
                for p in parts {
                    guard let i = Self.parseInt(p) else { return .failure(invalid("has an item that is not an integer", wire)) }
                    ints.append(i)
                }
                return .success(.intList(ints))
            }
            return .success(.stringList(parts))
        case .json:
            return .success(.json(wire))
        }
    }

    static func parseInt(_ s: String) -> Int? {
        guard !s.isEmpty, s.allSatisfy({ $0.isASCII && ($0.isNumber || $0 == "-") }) else { return nil }
        return Int(s)
    }

    static func parseDouble(_ s: String) -> Double? {
        // Double(_:) is locale-independent; reject nan and inf, which it accepts.
        guard let d = Double(s), d.isFinite else { return nil }
        return d
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
