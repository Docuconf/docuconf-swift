import Foundation

/// A set of secret keys that are all valid at once, so one can be rotated without an outage (contract type
/// `keySet`, SPEC §4.3 and §6.1). It is for the side that verifies: webhook signatures, inbound API keys, JWT HMAC
/// verification, cookie-signing fallbacks.
///
/// ```swift
/// @Env("webhook.keys", "Keys that verify webhook signatures", .keyLength(32...256))
/// var webhookKeys: KeySet
/// ```
///
/// A key set is always secret: it has no default, it prints as `<redacted>`, and no error message holds a key.
/// The platform sets it like a list, `old,new` during a rotation. Keys are never trimmed, and an empty key (a
/// stray separator) is always out of range. `.keys(1...2)` bounds the number of keys (1 to 2 by default), and
/// `.keyLength(_:)` the length of each, in characters.
///
/// Check a presented API key with ``contains(_:)``, or a signature with ``verify(_:)``:
///
/// ```swift
/// let ok = config.webhookKeys.verify { key in
///     let mac = HMAC<SHA256>.authenticationCode(for: body, using: SymmetricKey(data: key))
///     return HMAC<SHA256>.isValidAuthenticationCode(mac, authenticating: signature, using: SymmetricKey(data: key))
/// }
/// ```
public struct KeySet: EnvBaseValue, Sendable, Hashable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    /// The keys, in the order the platform gave them (during a rotation, usually the old key first).
    public let keys: [String]

    public init(_ keys: [String]) {
        self.keys = keys
    }

    /// The number of keys.
    public var count: Int { keys.count }

    /// Whether `candidate` is one of the keys, such as an API key a caller presents. It is compared with every key
    /// in constant time, so the time taken depends only on the number of keys and the lengths involved, never on
    /// which key matched or how much of one.
    public func contains(_ candidate: String) -> Bool {
        let c = Array(candidate.utf8)
        var found: UInt8 = 0
        for key in keys {
            found |= Self.constantTimeEqual(Array(key.utf8), c)
        }
        return found == 1
    }

    /// Calls `check` with each key's UTF-8 bytes and returns whether any call returned `true`. It is for checks
    /// that need the key itself, such as an HMAC. Every key is tried, even after one matches, so the time taken
    /// does not say which key matched; `check` should compare in constant time itself (as
    /// `HMAC.isValidAuthenticationCode` does).
    public func verify(_ check: (Data) throws -> Bool) rethrows -> Bool {
        var ok = false
        for key in keys where try check(Data(key.utf8)) {
            ok = true
        }
        return ok
    }

    /// `1` when `a` and `b` are equal, else `0`, in time that depends only on their lengths.
    static func constantTimeEqual(_ a: [UInt8], _ b: [UInt8]) -> UInt8 {
        var diff = UInt8(truncatingIfNeeded: a.count ^ b.count)
        let n = Swift.max(a.count, b.count)
        for i in 0..<n {
            let x = i < a.count ? a[i] : 0
            let y = i < b.count ? b[i] : 0
            diff |= x ^ y
        }
        return diff == 0 ? 1 : 0
    }

    // MARK: EnvBaseValue

    public static var varType: VarType { .keySet }

    public static func describe(_ spec: inout VarSpec) throws {
        spec.secret = true
        spec.items = nil
    }

    public init(parsed: ParsedValue) throws {
        guard case .stringList(let l) = parsed else { throw Self.mismatch(parsed) }
        self.init(l)
    }

    public var parsed: ParsedValue { .stringList(keys) }

    /// Never exported: a key set is secret, so it has no default.
    public var contractValue: JSONValue { .array(keys.map(JSONValue.string)) }

    // MARK: Printing

    /// Always `<redacted>`.
    public var description: String { Redaction.redacted }

    /// `KeySet(<redacted>)`.
    public var debugDescription: String { "KeySet(\(Redaction.redacted))" }

    /// `dump` shows no keys.
    public var customMirror: Mirror { Mirror(self, children: [:], displayStyle: nil) }
}

extension VarRule where Base == KeySet {
    /// The `csv` separator between keys (`,` by default). Keys are never trimmed.
    public static func separator(_ s: String) -> Self { Self { $0.separator = s } }
    /// The fewest and most keys (`minKeys`, `maxKeys`; 1 and 2 by default). During a rotation the set holds the
    /// old and the new key, so `maxKeys` is at least 2 for a key that rotates.
    public static func keys(_ r: ClosedRange<Int>) -> Self { Self { $0.minKeys = r.lowerBound; $0.maxKeys = r.upperBound } }
    public static func minKeys(_ n: Int) -> Self { Self { $0.minKeys = n } }
    public static func maxKeys(_ n: Int) -> Self { Self { $0.maxKeys = n } }
    /// Bounds on the length of every key (`keyMinLength`, `keyMaxLength`), in Unicode scalars (code points).
    public static func keyLength(_ r: ClosedRange<Int>) -> Self {
        Self { $0.keyMinLength = r.lowerBound; $0.keyMaxLength = r.upperBound }
    }
    public static func keyMinLength(_ n: Int) -> Self { Self { $0.keyMinLength = n } }
    public static func keyMaxLength(_ n: Int) -> Self { Self { $0.keyMaxLength = n } }
}
