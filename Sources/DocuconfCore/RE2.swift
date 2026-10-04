import Foundation

/// RE2 patterns (SPEC §4.3): rejected at declaration time when they use features outside RE2, and matched
/// anywhere in the value (partial match), as CUE's `=~` and JSON Schema's `pattern` do.
public enum RE2 {
    /// Returns why `pattern` is not an RE2 pattern this SDK can match exactly, or `nil` if it is fine.
    public static func problem(in pattern: String) -> String? {
        let s = Array(pattern.unicodeScalars)
        var i = 0
        var inClass = false
        while i < s.count {
            let c = s[i]
            if c == "\\" {
                guard i + 1 < s.count else { return "ends with a lone backslash" }
                let n = s[i + 1]
                if !inClass {
                    if ("1"..."9").contains(n) { return "uses a backreference (\\\(n)), which RE2 does not support" }
                    if n == "k" || n == "g" { return "uses a backreference (\\\(n)), which RE2 does not support" }
                    if n == "G" || n == "Z" { return "uses \\\(n), which RE2 does not support" }
                }
                i += 2
                continue
            }
            if inClass {
                if c == "[", let (_, end) = posixClass(s, at: i) {
                    i = end
                    continue
                }
                if c == "]" { inClass = false }
                i += 1
                continue
            }
            switch c {
            case "[":
                inClass = true
                // A ']' right after '[' or '[^' is a literal.
                if i + 1 < s.count, s[i + 1] == "^" { i += 1 }
                if i + 1 < s.count, s[i + 1] == "]" { i += 1 }
            case "(":
                let rest = String(String.UnicodeScalarView(s[(i + 1)...].prefix(4)))
                for (prefix, what) in [("?=", "lookahead"), ("?!", "lookahead"), ("?<=", "lookbehind"),
                                       ("?<!", "lookbehind"), ("?>", "an atomic group"), ("?(", "a conditional"),
                                       ("?#", "an inline comment"), ("?|", "a branch reset")]
                where rest.hasPrefix(prefix) {
                    return "uses \(what) (\(prefix)), which RE2 does not support"
                }
            case "*", "+", "?", "}":
                if i + 1 < s.count, s[i + 1] == "+" {
                    return "uses a possessive quantifier (\(c)+), which RE2 does not support"
                }
            default:
                break
            }
            i += 1
        }
        if inClass { return "has an unterminated character class" }
        do {
            _ = try compile(pattern)
        } catch {
            return "is not a valid regular expression: \(error)"
        }
        return nil
    }

    /// Whether `pattern` matches anywhere in `text`.
    public static func matches(_ pattern: String, _ text: String) -> Bool {
        guard let regex = try? compile(pattern) else { return false }
        return text.firstMatch(of: regex) != nil
    }

    /// Compiles an RE2 pattern with Swift Regex, matching Unicode scalars (as RE2 does) rather than
    /// grapheme clusters. As in RE2, `\d`, `\w`, `\s`, `\b` and the POSIX classes are ASCII-only.
    /// Python-style named groups `(?P<name>...)`, which RE2 also accepts, are rewritten
    /// to `(?<name>...)`. Outside multi-line mode, RE2's `$` matches only at the very end of the text, so it
    /// is rewritten to `\z`.
    static func compile(_ pattern: String) throws -> Regex<AnyRegexOutput> {
        try Regex(translate(pattern))
            .matchingSemantics(.unicodeScalar)
            .asciiOnlyWordCharacters()
            .asciiOnlyDigits()
            .asciiOnlyWhitespace()
            .asciiOnlyCharacterClasses()
            .wordBoundaryKind(RegexWordBoundaryKind.simple)
    }

    static let posixClasses: [String: String] = [
        "alnum": "0-9A-Za-z", "alpha": "A-Za-z", "ascii": "\\x00-\\x7F", "blank": "\\t ",
        "cntrl": "\\x00-\\x1F\\x7F", "digit": "0-9", "graph": "!-~", "lower": "a-z", "print": " -~",
        "punct": "!-/:-@\\[-`{-~", "space": "\\t\\n\\x0B\\f\\r ", "upper": "A-Z", "word": "0-9A-Za-z_",
        "xdigit": "0-9A-Fa-f",
    ]

    /// A POSIX class such as `[:alpha:]` starting at `i` inside a character class: its name and the index after it.
    static func posixClass(_ s: [Unicode.Scalar], at i: Int) -> (String, Int)? {
        guard i + 1 < s.count, s[i + 1] == ":" else { return nil }
        var j = i + 2
        var name = ""
        while j + 1 < s.count, s[j] != ":" {
            name.unicodeScalars.append(s[j])
            j += 1
        }
        guard j + 1 < s.count, s[j] == ":", s[j + 1] == "]", !name.isEmpty else { return nil }
        return (name, j + 2)
    }

    /// Whether the pattern sets the `m` flag anywhere, as in `(?m)` or `(?im:...)`.
    static func usesMultilineFlag(_ pattern: String) -> Bool {
        var rest = Substring(pattern)
        while let r = rest.range(of: "(?") {
            let flags = rest[r.upperBound...].prefix { $0.isLetter || $0 == "-" }
            if flags.prefix(while: { $0 != "-" }).contains("m") { return true }
            rest = rest[r.upperBound...]
        }
        return false
    }

    static func translate(_ pattern: String) -> String {
        let s = Array(pattern.unicodeScalars)
        var out = String.UnicodeScalarView()
        var i = 0
        var inClass = false
        let multiline = usesMultilineFlag(pattern)
        while i < s.count {
            let c = s[i]
            if c == "\\", i + 1 < s.count {
                out.append(c)
                out.append(s[i + 1])
                i += 2
                continue
            }
            if inClass {
                if c == "[", let (name, end) = posixClass(s, at: i) {
                    // RE2's POSIX classes are ASCII-only; Swift's are Unicode, so spell them out.
                    out.append(contentsOf: (posixClasses[name] ?? "[:\(name):]").unicodeScalars)
                    i = end
                    continue
                }
                if c == "]" { inClass = false }
                out.append(c)
                i += 1
                continue
            }
            if c == "[" {
                inClass = true
                out.append(c)
                if i + 1 < s.count, s[i + 1] == "^" { out.append(s[i + 1]); i += 1 }
                if i + 1 < s.count, s[i + 1] == "]" { out.append(s[i + 1]); i += 1 }
                i += 1
                continue
            }
            if c == "(", i + 2 < s.count, s[i + 1] == "?", s[i + 2] == "P", i + 3 < s.count, s[i + 3] == "<" {
                out.append(contentsOf: "(?".unicodeScalars)
                i += 3
                continue
            }
            if c == "$", !multiline {
                out.append(contentsOf: "\\z".unicodeScalars)
                i += 1
                continue
            }
            out.append(c)
            i += 1
        }
        return String(out)
    }
}
