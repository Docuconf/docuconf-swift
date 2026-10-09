import Crypto
import Docuconf
import Foundation

/// Checks the signature on incoming payment webhooks against the key set in WEBHOOK_KEYS.
enum Webhook {
    /// Whether `signature`, the hex-encoded HMAC-SHA256 of `body`, was made with any of `keys`. Accepting every key
    /// in the set is what lets a key be rotated: during the overlap the old and the new key both work.
    static func verify(keys: KeySet, body: Data, signature: String) -> Bool {
        guard let mac = hexDecoded(signature) else { return false }
        // `KeySet.verify` tries every key, even after a match, and the HMAC check compares in constant time, so the
        // time taken does not say which key matched.
        return keys.verify { key in
            HMAC<SHA256>.isValidAuthenticationCode(mac, authenticating: body, using: SymmetricKey(data: key))
        }
    }

    /// The hex-encoded HMAC-SHA256 of `body` under `key`, as a sender makes it.
    static func sign(key: String, body: Data) -> String {
        HMAC<SHA256>.authenticationCode(for: body, using: SymmetricKey(data: Data(key.utf8)))
            .map { String(format: "%02x", $0) }.joined()
    }

    private static func hexDecoded(_ hex: String) -> Data? {
        let digits = Array(hex.utf8)
        guard digits.count % 2 == 0 else { return nil }
        var out = Data(capacity: digits.count / 2)
        for i in stride(from: 0, to: digits.count, by: 2) {
            guard let hi = nibble(digits[i]), let lo = nibble(digits[i + 1]) else { return nil }
            out.append(hi << 4 | lo)
        }
        return out
    }

    private static func nibble(_ c: UInt8) -> UInt8? {
        switch c {
        case UInt8(ascii: "0")...UInt8(ascii: "9"): c - UInt8(ascii: "0")
        case UInt8(ascii: "a")...UInt8(ascii: "f"): c - UInt8(ascii: "a") + 10
        case UInt8(ascii: "A")...UInt8(ascii: "F"): c - UInt8(ascii: "A") + 10
        default: nil
        }
    }
}
