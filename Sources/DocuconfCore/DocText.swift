import Foundation

/// Splits an input's documentation into the contract's `description` and `details` (SPEC §4.2, §14.7).
///
/// Swift doc comments are trivia that a property wrapper never sees, so an input is documented in its
/// declaration instead: the description argument of ``Env`` or ``FileInput`` may be a whole doc comment, in the
/// DocC Markdown a `///` comment holds, usually as a multi-line string literal. Its first paragraph is the
/// description, on one line, and the rest the details, converted to CommonMark:
///
/// - DocC symbol links (` ``Name`` `) become code spans, and `<doc:Article>` links the article's name.
/// - Callouts become bold labels (`- Note: x` is `**Note:** x`, as are `Important`, `Warning`, `Tip`,
///   `Attention`, `Precondition`, `Postcondition`, `Remark`, `Experiment`, and `See Also`), and the DocC aside
///   `> Note: x` keeps its quote: `> **Note:** x`.
/// - Callouts that document functions (`- Parameter`, `- Parameters:`, `- Returns:`, `- Throws:`) are dropped.
/// - `///` markers, when every line has one, are stripped, so a comment can be pasted as is.
///
/// Fenced and indented code is left alone. Text that does not start with a paragraph (it starts with a list or
/// code) is all description. ``VarRule/details(_:)`` and ``FileRule/details(_:)`` set details explicitly.
public enum DocText {
    /// The most characters (Unicode scalars) details may have.
    public static let maxDetails = 4000

    /// The description (first paragraph, on one line) and the details (the rest, `nil` when there is none).
    public static func split(_ text: String) -> (description: String, details: String?) {
        let lines = unindent(stripMarkers(text.components(separatedBy: "\n").map(trimTrailing)))
        guard let first = lines.first else { return ("", nil) }
        if !startsParagraph(first) { return (oneLine(lines.map(convertInline)), nil) }
        let end = lines.firstIndex(of: "") ?? lines.count
        let description = oneLine(lines[..<end].map(convertInline))
        let rest = end < lines.count ? convertBlocks(Array(lines[(end + 1)...])) : ""
        return (description, rest.isEmpty ? nil : rest)
    }

    /// The problem with an input's details, or `nil`: they must not be blank, and have at most ``maxDetails``
    /// characters.
    public static func problem(_ details: String?) -> String? {
        guard let d = details else { return nil }
        if d.allSatisfy(\.isWhitespace) { return "details must not be blank" }
        let n = d.unicodeScalars.count
        return n > maxDetails ? "details are \(n) characters; details may have at most \(maxDetails)" : nil
    }

    static func trimTrailing(_ s: String) -> String {
        var s = Substring(s)
        while let c = s.last, c == " " || c == "\t" || c == "\r" { s = s.dropLast() }
        return String(s)
    }

    static func indent(_ s: String) -> Int { s.prefix { $0 == " " || $0 == "\t" }.count }

    static func stripMarkers(_ lines: [String]) -> [String] {
        let text = lines.filter { !$0.allSatisfy(\.isWhitespace) }
        guard !text.isEmpty, text.allSatisfy({ $0.drop(while: { $0 == " " || $0 == "\t" }).hasPrefix("///") }) else {
            return lines
        }
        return lines.map { l in
            let t = l.drop(while: { $0 == " " || $0 == "\t" })
            return t.hasPrefix("///") ? String(t.dropFirst(3)) : l
        }
    }

    static func unindent(_ lines: [String]) -> [String] {
        let n = lines.filter { !$0.allSatisfy(\.isWhitespace) }.map(indent).min() ?? 0
        var out = lines.map { $0.allSatisfy(\.isWhitespace) ? "" : String($0.dropFirst(n)) }
        while out.first == "" { out.removeFirst() }
        while out.last == "" { out.removeLast() }
        return out
    }

    static func startsParagraph(_ line: String) -> Bool {
        if indent(line) >= 4 { return false }
        let t = line.drop(while: { $0 == " " })
        for p in ["```", "~~~", "#", ">", "- ", "* ", "+ ", "|"] where t.hasPrefix(p) { return false }
        let digits = t.prefix(while: \.isNumber)
        let after = t.dropFirst(digits.count)
        return digits.isEmpty || !(after.hasPrefix(". ") || after.hasPrefix(") "))
    }

    static func oneLine(_ lines: [String]) -> String {
        lines.flatMap { $0.split(whereSeparator: \.isWhitespace) }.joined(separator: " ")
    }

    static let callouts = [
        "note": "Note", "important": "Important", "warning": "Warning", "tip": "Tip", "attention": "Attention",
        "precondition": "Precondition", "postcondition": "Postcondition", "remark": "Remark",
        "experiment": "Experiment", "seealso": "See Also", "see also": "See Also",
    ]
    static let dropped = ["parameter", "parameters", "returns", "throws"]

    /// The callout name and the text after `Name:` in `- Name: text`, or `nil`.
    static func callout(_ t: Substring) -> (name: String, rest: Substring)? {
        guard t.hasPrefix("- "), let colon = t.firstIndex(of: ":") else { return nil }
        let name = t[t.index(t.startIndex, offsetBy: 2)..<colon].lowercased()
        let key = name.hasPrefix("parameter ") ? "parameter" : name
        guard callouts[key] != nil || dropped.contains(key) else { return nil }
        return (key, t[t.index(after: colon)...].drop(while: { $0 == " " }))
    }

    static func convertBlocks(_ lines: [String]) -> String {
        var out: [String] = []
        var fence: String?
        var droppingCallout = false
        for line in lines {
            let t = line.drop(while: { $0 == " " })
            if let f = fence {
                out.append(line)
                if t.hasPrefix(f) && t.allSatisfy({ $0 == f.first }) { fence = nil }
                continue
            }
            if t.hasPrefix("```") || t.hasPrefix("~~~") {
                fence = String(t.prefix(while: { $0 == t.first }))
                out.append(line)
                droppingCallout = false
                continue
            }
            if indent(line) >= 4 && !droppingCallout {
                out.append(line)
                continue
            }
            if droppingCallout {
                // A dropped callout's continuation lines are indented under it.
                if !line.isEmpty && indent(line) > 0 { continue }
                droppingCallout = false
            }
            let pad = String(line.prefix(indent(line)))
            if let (name, rest) = callout(t) {
                if dropped.contains(name) {
                    droppingCallout = true
                    continue
                }
                out.append(pad + "**\(callouts[name]!):** " + convertInline(String(rest)))
                continue
            }
            if t.hasPrefix("> ") {
                let body = t.dropFirst(2)
                if let colon = body.firstIndex(of: ":"), let label = callouts[body[..<colon].lowercased()] {
                    let rest = body[body.index(after: colon)...].drop(while: { $0 == " " })
                    out.append(pad + "> **\(label):** " + convertInline(String(rest)))
                    continue
                }
            }
            out.append(convertInline(line))
        }
        // Dropped callouts can leave blank runs.
        var tidy: [String] = []
        for l in out where !(l.isEmpty && (tidy.last ?? "") == "") { tidy.append(l) }
        while tidy.last == "" { tidy.removeLast() }
        return tidy.joined(separator: "\n")
    }

    /// ` ``Symbol`` ` becomes `` `Symbol` `` and `<doc:Article>` becomes `Article`, outside code spans.
    static func convertInline(_ s: String) -> String {
        var out = ""
        var i = s.startIndex
        while i < s.endIndex {
            if s[i...].hasPrefix("``"), let close = s[s.index(i, offsetBy: 2)...].range(of: "``") {
                let symbol = s[s.index(i, offsetBy: 2)..<close.lowerBound]
                if !symbol.isEmpty && !symbol.contains("`") {
                    out += "`\(symbol)`"
                    i = close.upperBound
                    continue
                }
            }
            if s[i] == "`" {
                let run = s[i...].prefix { $0 == "`" }
                let after = s.index(i, offsetBy: run.count)
                if let close = s[after...].range(of: String(run)) {
                    out += s[i..<close.upperBound]
                    i = close.upperBound
                } else {
                    out += run
                    i = after
                }
                continue
            }
            if s[i...].hasPrefix("<doc:"), let close = s[i...].firstIndex(of: ">") {
                let name = s[s.index(i, offsetBy: 5)..<close]
                out += name.split(separator: "/").last.map(String.init) ?? String(name)
                i = s.index(after: close)
                continue
            }
            out.append(s[i])
            i = s.index(after: i)
        }
        return out
    }
}
