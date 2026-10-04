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
