import Foundation

/// Durations in Go syntax (`1h30m`), the form contracts and platform values always use (SPEC §4.3).
public enum GoDuration {
    private static let units: [(suffix: String, nanoseconds: Int64)] = [
        ("h", 3_600_000_000_000), ("m", 60_000_000_000), ("s", 1_000_000_000),
        ("ms", 1_000_000), ("us", 1_000), ("ns", 1),
    ]

    /// Formats a non-negative duration in canonical form, omitting zero units: 90 seconds is `1m30s`,
    /// 1.5 hours is `1h30m`, zero is `0s`. Precision below a nanosecond is dropped.
    public static func format(_ duration: Duration) -> String {
        var ns = nanoseconds(duration)
        precondition(ns >= 0, "durations in a contract cannot be negative")
        if ns == 0 { return "0s" }
        var out = ""
        for (suffix, size) in units where ns >= size {
            out += "\(ns / size)\(suffix)"
            ns %= size
        }
        return out
    }

    /// Parses a Go-syntax duration of the restricted form the contract allows (`^([0-9]+(ns|us|ms|s|m|h))+$`).
    public static func parse(_ text: String) -> Duration? {
        var total: Int64 = 0
        var rest = Substring(text)
        guard !rest.isEmpty else { return nil }
        while !rest.isEmpty {
            let digits = rest.prefix { $0.isASCII && $0.isNumber }
            guard !digits.isEmpty, let n = Int64(digits) else { return nil }
            rest = rest.dropFirst(digits.count)
            guard let unit = units.first(where: { rest.hasPrefix($0.suffix) && !(($0.suffix == "m") && rest.hasPrefix("ms")) })
            else { return nil }
            rest = rest.dropFirst(unit.suffix.count)
            let (product, overflow) = n.multipliedReportingOverflow(by: unit.nanoseconds)
            guard !overflow else { return nil }
            let (sum, overflow2) = total.addingReportingOverflow(product)
            guard !overflow2 else { return nil }
            total = sum
        }
        return .nanoseconds(total)
    }

    /// Whole nanoseconds in a duration (truncated).
    public static func nanoseconds(_ duration: Duration) -> Int64 {
        let (seconds, attoseconds) = duration.components
        return seconds * 1_000_000_000 + attoseconds / 1_000_000_000
    }
}

extension DurationEncoding {
    /// Parses a duration written in this encoding (SPEC §5). Returns `nil` when the text is not in this form or
    /// does not fit in 64 bits of nanoseconds. Only `go` admits a sign, as Go's `time.ParseDuration` does; a
    /// negative result is left to the range check.
    public func parse(_ text: String) -> Duration? {
        let ns: Int64?
        switch self {
        case .go: ns = Self.goNanoseconds(Substring(text))
        case .iso8601: ns = Self.iso8601Nanoseconds(text)
        case .seconds: ns = Self.secondsNanoseconds(Substring(text))
        case .timespan: ns = Self.timespanNanoseconds(text)
        }
        return ns.map { .nanoseconds($0) }
    }

    private static let second: Int64 = 1_000_000_000

    /// Sums `parts` of (count, nanoseconds per unit), or `nil` on overflow.
    private static func sum(_ parts: [(Int64, Int64)]) -> Int64? {
        var total: Int64 = 0
        for (n, unit) in parts {
            let (p, o1) = n.multipliedReportingOverflow(by: unit)
            let (t, o2) = total.addingReportingOverflow(p)
            if o1 || o2 { return nil }
            total = t
        }
        return total
    }

    /// `digits` as a number, or `nil` when empty, not ASCII digits, or too large.
    private static func number(_ digits: Substring) -> Int64? {
        guard !digits.isEmpty, digits.allSatisfy({ $0.isASCII && $0.isNumber }) else { return nil }
        return Int64(digits)
    }

    /// Nanoseconds in a decimal fraction (`5` in `1.5` is 500 ms of a second), truncated below a nanosecond.
    private static func fraction(_ digits: Substring, of unit: Int64) -> Int64? {
        guard !digits.isEmpty, digits.allSatisfy({ $0.isASCII && $0.isNumber }) else { return nil }
        // Exact for units up to an hour with nine digits; extra digits only refine below a nanosecond.
        let nine = String(digits.prefix(9)).padding(toLength: 9, withPad: "0", startingAt: 0)
        guard let n = Int64(nine) else { return nil }
        let (whole, rem) = unit.quotientAndRemainder(dividingBy: second)
        return n * whole + n * rem / second
    }

    /// A seconds count with an optional fraction: `90`, `0.25`.
    private static func secondsNanoseconds(_ text: Substring) -> Int64? {
        let parts = text.split(separator: ".", maxSplits: 1, omittingEmptySubsequences: false)
        guard let secs = number(parts[0]) else { return nil }
        let frac = parts.count == 2 ? fraction(parts[1], of: second) : 0
        guard let frac, let whole = sum([(secs, second)]) else { return nil }
        return sum([(whole, 1), (frac, 1)])
    }

    /// Go's `time.ParseDuration` syntax: `1h2m3.5s`, `1500ms`, `-1s`, `0`.
    private static func goNanoseconds(_ text: Substring) -> Int64? {
        var rest = text
        var negative = false
        if let sign = rest.first, sign == "-" || sign == "+" {
            negative = sign == "-"
            rest = rest.dropFirst()
        }
        if rest == "0" { return 0 }
        guard !rest.isEmpty else { return nil }
        let units: [(String, Int64)] = [
            ("ns", 1), ("us", 1_000), ("µs", 1_000), ("μs", 1_000), ("ms", 1_000_000),
            ("s", second), ("m", 60 * second), ("h", 3600 * second),
        ]
        var total: Int64 = 0
        while !rest.isEmpty {
            let whole = rest.prefix { $0.isASCII && $0.isNumber }
            rest = rest.dropFirst(whole.count)
            var frac: Substring = ""
            if rest.first == "." {
                rest = rest.dropFirst()
                frac = rest.prefix { $0.isASCII && $0.isNumber }
                rest = rest.dropFirst(frac.count)
            }
            guard !(whole.isEmpty && frac.isEmpty) else { return nil }
            // Longest unit first, so `ms` is not read as `m`.
            guard let (suffix, size) = units.filter({ rest.hasPrefix($0.0) }).max(by: { $0.0.count < $1.0.count }) else {
                return nil
            }
            rest = rest.dropFirst(suffix.count)
            let w = whole.isEmpty ? 0 : number(whole)
            let f = frac.isEmpty ? 0 : fraction(frac, of: size)
            guard let w, let f, let part = sum([(w, size), (f, 1)]), let t = sum([(total, 1), (part, 1)]) else { return nil }
            total = t
        }
        return negative ? -total : total
    }

    /// ISO 8601 durations of days and time: `PT90S`, `PT1.5S`, `P1DT2H`, `PT1H30M`.
    private static func iso8601Nanoseconds(_ text: String) -> Int64? {
        guard text.hasPrefix("P") else { return nil }
        var rest = Substring(text.dropFirst())
        var parts: [(Int64, Int64)] = []
        var inTime = false
        var seen = Set<Character>()
        while !rest.isEmpty {
            if rest.first == "T" {
                guard !inTime else { return nil }
                inTime = true
                rest = rest.dropFirst()
                guard !rest.isEmpty else { return nil }
                continue
            }
            let num = rest.prefix { ($0.isASCII && $0.isNumber) || $0 == "." || $0 == "," }
            rest = rest.dropFirst(num.count)
            guard let designator = rest.first, !num.isEmpty else { return nil }
            rest = rest.dropFirst()
            let unit: Int64
            switch (inTime, designator) {
            case (false, "W"): unit = 7 * 86_400 * second
            case (false, "D"): unit = 86_400 * second
            case (true, "H"): unit = 3600 * second
            case (true, "M"): unit = 60 * second
            case (true, "S"): unit = second
            default: return nil
            }
            guard seen.insert(designator).inserted else { return nil }
            let pieces = num.split(whereSeparator: { $0 == "." || $0 == "," }).map { $0 }
            // A fraction only on the last (smallest) component, as ISO 8601 allows; in practice seconds.
            if num.contains(where: { $0 == "." || $0 == "," }) {
                guard pieces.count == 2, rest.isEmpty, let w = number(pieces[0]), let f = fraction(pieces[1], of: unit) else {
                    return nil
                }
                parts.append((w, unit))
                parts.append((f, 1))
            } else {
                guard let w = number(num) else { return nil }
                parts.append((w, unit))
            }
        }
        guard !parts.isEmpty else { return nil }
        return sum(parts)
    }

    /// .NET `TimeSpan` text: `[d.]hh:mm[:ss[.fffffff]]`.
    private static func timespanNanoseconds(_ text: String) -> Int64? {
        let fields = text.split(separator: ":", omittingEmptySubsequences: false)
        guard fields.count == 2 || fields.count == 3 else { return nil }
        // Days, if any, are before a '.' in the first field.
        let first = fields[0].split(separator: ".", omittingEmptySubsequences: false)
        guard first.count <= 2 else { return nil }
        let days = first.count == 2 ? number(first[0]) : 0
        guard let days, let hours = number(first[first.count - 1]), hours < 24 else { return nil }
        guard let minutes = number(fields[1]), minutes < 60, fields[1].count <= 2, first[first.count - 1].count <= 2 else {
            return nil
        }
        var seconds: Int64 = 0
        var frac: Int64 = 0
        if fields.count == 3 {
            let s = fields[2].split(separator: ".", omittingEmptySubsequences: false)
            guard s.count <= 2, s[0].count <= 2, let secs = number(s[0]), secs < 60 else { return nil }
            seconds = secs
            if s.count == 2 {
                guard s[1].count <= 7, let f = fraction(s[1], of: second) else { return nil }
                frac = f
            }
        }
        return sum([(days, 86_400 * second), (hours, 3600 * second), (minutes, 60 * second), (seconds, second), (frac, 1)])
    }
}
