/// Maps swift-configuration keys to environment variable names.
public enum EnvName {
    /// The environment variable name swift-configuration's `EnvironmentVariablesProvider` reads for a key:
    /// components joined with `_`, camelCase word boundaries marked with `_`, upper-cased, and every other
    /// non-alphanumeric character replaced by `_`. `http.serverTimeout` becomes `HTTP_SERVER_TIMEOUT`.
    ///
    /// This mirrors the provider's internal key encoder, so a docuconf declaration and a plain
    /// `ConfigReader` lookup of the same key read the same variable. A test pins the two together.
    public static func forKey(_ key: String) -> String {
        key.split(separator: ".", omittingEmptySubsequences: false).map { component -> String in
            var chars = Array(component)
            var i = 0
            while i < chars.count - 1 {
                if chars[i].isLowercase && chars[i + 1].isUppercase {
                    chars.insert("_", at: i + 1)
                    i += 1
                }
                i += 1
            }
            return String(chars).uppercased().map { $0.isLetter || $0.isNumber ? String($0) : "_" }.joined()
        }.joined(separator: "_")
    }

    /// Whether `name` is a valid contract variable name (`^[A-Z][A-Z0-9_]*$`).
    public static func isValid(_ name: String) -> Bool {
        guard let first = name.unicodeScalars.first, ("A"..."Z").contains(first) else { return false }
        return name.unicodeScalars.allSatisfy { ("A"..."Z").contains($0) || ("0"..."9").contains($0) || $0 == "_" }
    }

    /// Whether `name` is a valid file input name (a DNS label of at most 42 characters, `^[a-z]([-a-z0-9]{0,40}[a-z0-9])?$`).
    public static func isValidInputName(_ name: String) -> Bool {
        let s = Array(name.unicodeScalars)
        guard (1...42).contains(s.count), ("a"..."z").contains(s[0]) else { return false }
        let lowerDigit: (Unicode.Scalar) -> Bool = { ("a"..."z").contains($0) || ("0"..."9").contains($0) }
        if s.count > 1 && !lowerDigit(s[s.count - 1]) { return false }
        return s.allSatisfy { lowerDigit($0) || $0 == "-" }
    }

    /// Whether a variable name looks like a feature flag (SPEC §10).
    public static func looksLikeFeatureFlag(_ name: String) -> Bool {
        ["FF_", "FEATURE_", "FEATURE_FLAG_", "ENABLE_"].contains { name.hasPrefix($0) }
    }
}
