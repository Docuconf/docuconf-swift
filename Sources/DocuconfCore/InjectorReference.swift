/// References that runtime injectors resolve before the app starts (SPEC §4.5.1): Bank-Vaults (`vault:`),
/// 1Password's `op run` (`op://`) and vals (`ref+`).
///
/// docuconf never resolves them (SPEC §11.2 item 4). A secret that still holds one at boot means the injector
/// did not run, and the app would otherwise use the reference itself as the secret.
public enum InjectorReference {
    /// The schemes recognised, as the value starts with them.
    public static let schemes = ["vault:", "op://", "ref+"]

    /// The scheme `value` starts with, if it looks like an unresolved reference.
    public static func scheme(of value: String) -> String? {
        schemes.first { value.hasPrefix($0) }
    }

    /// The violation for a secret variable that holds an unresolved reference, or `nil`. The message names
    /// the scheme, never the value.
    public static func violation(for name: String, value: String) -> Violation? {
        guard let scheme = scheme(of: value) else { return nil }
        return Violation(.invalidType, name, "holds an unresolved \(scheme) reference; the injector that should resolve it did not run")
    }
}
