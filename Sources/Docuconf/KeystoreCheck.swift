#if TLS
import Crypto
import DocuconfCore
import Foundation
import SwiftASN1

/// Opens keystores far enough to prove the password is right, without a platform keystore API:
/// a PKCS#12 file's MAC (RFC 7292) or a JKS file's keyed SHA-1 digest.
enum KeystoreCheck {
    /// Returns why the keystore does not open, or `nil` if it does.
    static func problem(_ data: Data, format: KeystoreFormat, password: String) -> String? {
        switch format {
        case .pkcs12: return pkcs12Problem([UInt8](data), password: password)
        case .jks: return jksProblem([UInt8](data), password: password)
        }
    }

    // MARK: JKS

    static func jksProblem(_ bytes: [UInt8], password: String) -> String? {
        guard bytes.count > 28, bytes.prefix(4) == [0xFE, 0xED, 0xFE, 0xED] || bytes.prefix(4) == [0xCE, 0xCE, 0xCE, 0xCE] else {
            return "not a JKS file"
        }
        var hasher = Insecure.SHA1()
        var pw: [UInt8] = []
        for unit in password.utf16 { pw += [UInt8(unit >> 8), UInt8(unit & 0xFF)] }
        hasher.update(data: pw)
        hasher.update(data: Array("Mighty Aphrodite".utf8))
        hasher.update(data: bytes.dropLast(20))
        return Array(hasher.finalize()) == Array(bytes.suffix(20)) ? nil : "the password is wrong or the file is corrupt"
    }

    // MARK: PKCS#12

    static let oidData: ASN1ObjectIdentifier = [1, 2, 840, 113549, 1, 7, 1]
    static let oidSHA1: ASN1ObjectIdentifier = [1, 3, 14, 3, 2, 26]
    static let oidSHA256: ASN1ObjectIdentifier = [2, 16, 840, 1, 101, 3, 4, 2, 1]
    static let oidSHA384: ASN1ObjectIdentifier = [2, 16, 840, 1, 101, 3, 4, 2, 2]
    static let oidSHA512: ASN1ObjectIdentifier = [2, 16, 840, 1, 101, 3, 4, 2, 3]

    static func children(_ node: ASN1Node) -> [ASN1Node]? {
        if case .constructed(let c) = node.content { return Array(c) }
        return nil
    }

    static func primitive(_ node: ASN1Node) -> [UInt8]? {
        if case .primitive(let p) = node.content { return Array(p) }
        return nil
    }

    static func pkcs12Problem(_ bytes: [UInt8], password: String) -> String? {
        // PFX ::= SEQUENCE { version INTEGER, authSafe ContentInfo, macData MacData OPTIONAL }
        guard let pfx = try? DER.parse(bytes), let parts = children(pfx), parts.count >= 2,
            let authSafe = children(parts[1]), authSafe.count == 2,
            let contentType = try? ASN1ObjectIdentifier(derEncoded: authSafe[0])
        else { return "not a DER-encoded PKCS#12 file" }
        guard contentType == oidData else { return "uses public-key integrity mode, which this SDK cannot check" }
        // content [0] EXPLICIT OCTET STRING
        guard let wrapped = children(authSafe[1]), let octets = wrapped.first, let content = primitive(octets) else {
            return "not a DER-encoded PKCS#12 file"
        }
        guard parts.count >= 3 else { return nil }  // No MAC: nothing to check the password against.

        // MacData ::= SEQUENCE { mac DigestInfo, macSalt OCTET STRING, iterations INTEGER DEFAULT 1 }
        guard let macData = children(parts[2]), macData.count >= 2,
            let digestInfo = children(macData[0]), digestInfo.count == 2,
            let algorithm = children(digestInfo[0]), let oidNode = algorithm.first,
            let digestOID = try? ASN1ObjectIdentifier(derEncoded: oidNode),
            let expected = primitive(digestInfo[1]),
            let salt = primitive(macData[1])
        else { return "has a malformed MAC" }
        var iterations = 1
        if macData.count >= 3 {
            guard let n = try? Int(derEncoded: macData[2]), n > 0, n <= 10_000_000 else { return "has a malformed MAC" }
            iterations = n
        }

        let pw = bmpString(password)
        let actual: [UInt8]
        switch digestOID {
        case oidSHA1: actual = mac(Insecure.SHA1.self, password: pw, salt: salt, iterations: iterations, content: content)
        case oidSHA256: actual = mac(SHA256.self, password: pw, salt: salt, iterations: iterations, content: content)
        case oidSHA384: actual = mac(SHA384.self, password: pw, salt: salt, iterations: iterations, content: content)
        case oidSHA512: actual = mac(SHA512.self, password: pw, salt: salt, iterations: iterations, content: content)
        default: return "uses an unsupported MAC algorithm (\(digestOID))"
        }
        return actual == expected ? nil : "the password is wrong or the file is corrupt"
    }

    /// The password as a null-terminated big-endian UTF-16 BMPString, as PKCS#12 key derivation uses it.
    static func bmpString(_ s: String) -> [UInt8] {
        var out: [UInt8] = []
        for unit in s.utf16 { out += [UInt8(unit >> 8), UInt8(unit & 0xFF)] }
        return out + [0, 0]
    }

    static func mac<H: HashFunction>(_ hash: H.Type, password: [UInt8], salt: [UInt8], iterations: Int, content: [UInt8]) -> [UInt8] {
        let key = pkcs12KDF(hash, id: 3, password: password, salt: salt, iterations: iterations, length: H.Digest.byteCount)
        return Array(HMAC<H>.authenticationCode(for: content, using: SymmetricKey(data: key)))
    }

    /// RFC 7292 appendix B.2 key derivation.
    static func pkcs12KDF<H: HashFunction>(_ hash: H.Type, id: UInt8, password: [UInt8], salt: [UInt8], iterations: Int, length: Int) -> [UInt8] {
        let u = H.Digest.byteCount
        let v = H.blockByteCount
        func stretch(_ x: [UInt8]) -> [UInt8] {
            guard !x.isEmpty else { return [] }
            let n = v * ((x.count + v - 1) / v)
            return (0..<n).map { x[$0 % x.count] }
        }
        let d = [UInt8](repeating: id, count: v)
        var i = stretch(salt) + stretch(password)
        var out: [UInt8] = []
        while out.count < length {
            var a = Array(H.hash(data: d + i))
            for _ in 1..<iterations { a = Array(H.hash(data: a)) }
            out += a
            if out.count >= length { break }
            // I_j = (I_j + B + 1) mod 2^(8v), for each v-byte block of I.
            let b = (0..<v).map { a[$0 % u] }
            for start in stride(from: 0, to: i.count, by: v) {
                var carry = 1
                for k in (0..<v).reversed() {
                    let sum = Int(i[start + k]) + Int(b[k]) + carry
                    i[start + k] = UInt8(sum & 0xFF)
                    carry = sum >> 8
                }
            }
        }
        return Array(out.prefix(length))
    }
}
#endif
