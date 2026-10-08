import DocuconfCore

/// Finds environment variables that look like misspellings of declared names (SPEC §11.2, typo hints).
enum TypoHint {
    /// A set variable that is not `name` but within a small edit distance of it: 2 for names longer than four
    /// characters, 1 for shorter ones (otherwise `HOST` would match the `HOME` every shell sets).
    static func nearMiss(of name: String, in setNames: some Sequence<String>) -> String? {
        let limit = name.count > 4 ? 2 : 1
        return setNames.filter { $0 != name && distance($0, name, limit: limit) <= limit }.sorted().first
    }

    /// Warnings for every set variable that is not declared but is close to a declared one. Never shows a value.
    static func warnings(declared: Set<String>, environment: [String: String]) -> [String] {
        var out: [String] = []
        for set in environment.keys.sorted() where !declared.contains(set) && !set.hasPrefix("DOCUCONF_") {
            let candidates = declared.filter { d in
                let limit = d.count > 4 ? 2 : 1
                return distance(set, d, limit: limit) <= limit
            }
            if let best = candidates.min(by: { (distance(set, $0, limit: 2), $0) < (distance(set, $1, limit: 2), $1) }) {
                out.append("\(set) is set but not declared; did you mean \(best)?")
            }
        }
        return out
    }

    /// Levenshtein distance, giving up early (returning `limit + 1`) once it exceeds `limit`.
    static func distance(_ a: String, _ b: String, limit: Int) -> Int {
        let a = Array(a.utf8), b = Array(b.utf8)
        if abs(a.count - b.count) > limit { return limit + 1 }
        var previous = Array(0...b.count)
        for i in 1...max(a.count, 1) where !a.isEmpty {
            var current = [i] + Array(repeating: 0, count: b.count)
            for j in 1...max(b.count, 1) where !b.isEmpty {
                current[j] = min(previous[j] + 1, current[j - 1] + 1, previous[j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1))
            }
            if current.min()! > limit { return limit + 1 }
            previous = current
        }
        return previous[b.count]
    }
}
