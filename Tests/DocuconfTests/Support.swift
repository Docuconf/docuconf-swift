import Crypto
import Docuconf
import Foundation
import SwiftASN1
import X509
import _CryptoExtras

/// A temporary directory used as `DOCUCONF_FILE_ROOT`, plus the environment for one load.
final class Sandbox: @unchecked Sendable {
    let root: URL
    var env: [String: String]
    private let lock = NSLock()
    private var _warnings: [String] = []

    init(_ vars: [String: String] = [:]) throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("docuconf-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        env = vars
        env["DOCUCONF_FILE_ROOT"] = root.path
        env["DOCUCONF_TERMINATION_LOG"] = root.appendingPathComponent("termination-log").path
    }

    deinit { try? FileManager.default.removeItem(at: root) }

    var warnings: [String] { lock.withLock { _warnings } }

    var terminationLog: String? { try? String(contentsOf: root.appendingPathComponent("termination-log"), encoding: .utf8) }

    /// Writes a file at an absolute in-container path, under the sandbox root.
    func write(_ path: String, _ content: String) throws { try write(path, Data(content.utf8)) }

    func write(_ path: String, _ data: Data) throws {
        let url = root.appendingPathComponent(String(path.dropFirst()))
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
    }

    func remove(_ path: String) throws {
        try FileManager.default.removeItem(at: root.appendingPathComponent(String(path.dropFirst())))
    }

    func options() -> LoadOptions {
        LoadOptions(environment: env, warn: { [weak self] w in self?.lock.withLock { self?._warnings.append(w) } })
    }

    func load<C: DocuconfConfig>(_ type: C.Type) async throws -> C {
        try await Docuconf.load(type, options: options())
    }

    /// The violations a load reports; fails the test if it succeeds.
    func violations<C: DocuconfConfig>(_ type: C.Type) async -> [Violation] {
        do {
            _ = try await load(type)
            return []
        } catch let e as ConfigurationError {
            return e.violations
        } catch {
            return [Violation(.invalidType, "unexpected", "\(error)")]
        }
    }

    static func fixture(_ name: String) throws -> Data {
        try Data(contentsOf: URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/\(name)"))
    }
}

/// Self-signed CAs and leaf certificates, generated with swift-certificates.
enum TestPKI {
    enum KeyKind { case p256, rsa, ed25519 }

    struct Issued {
        let certificate: Certificate
        let key: Certificate.PrivateKey
        var certificatePEM: String { try! certificate.serializeAsPEM().pemString }
        var keyPEM: String { try! key.serializeAsPEM().pemString }
    }

    static func key(_ kind: KeyKind) throws -> Certificate.PrivateKey {
        switch kind {
        case .p256: return Certificate.PrivateKey(P256.Signing.PrivateKey())
        case .rsa: return Certificate.PrivateKey(try _RSA.Signing.PrivateKey(keySize: .bits2048))
        case .ed25519: return Certificate.PrivateKey(Curve25519.Signing.PrivateKey())
        }
    }

    static func ca(_ name: String = "docuconf test CA") throws -> Issued {
        let key = try key(.p256)
        let subject = try DistinguishedName { CommonName(name) }
        let now = Date()
        let cert = try Certificate(
            version: .v3, serialNumber: .init(), publicKey: key.publicKey,
            notValidBefore: now - 3600, notValidAfter: now + 3650 * 86400,
            issuer: subject, subject: subject, signatureAlgorithm: .ecdsaWithSHA256,
            extensions: try Certificate.Extensions {
                Critical(BasicConstraints.isCertificateAuthority(maxPathLength: nil))
                Critical(KeyUsage(keyCertSign: true, cRLSign: true))
            },
            issuerPrivateKey: key)
        return Issued(certificate: cert, key: key)
    }

    static func leaf(
        dnsNames: [String], issuer: Issued, keyKind: KeyKind = .p256,
        notBefore: Date = Date() - 3600, notAfter: Date = Date() + 90 * 86400
    ) throws -> Issued {
        let key = try key(keyKind)
        let subject = try DistinguishedName { CommonName(dnsNames.first ?? "leaf") }
        let cert = try Certificate(
            version: .v3, serialNumber: .init(), publicKey: key.publicKey,
            notValidBefore: notBefore, notValidAfter: notAfter,
            issuer: issuer.certificate.subject, subject: subject,
            signatureAlgorithm: .ecdsaWithSHA256,  // test CAs use P-256 keys
            extensions: try Certificate.Extensions {
                Critical(BasicConstraints.notCertificateAuthority)
                Critical(KeyUsage(digitalSignature: true))
                SubjectAlternativeNames(dnsNames.map { .dnsName($0) })
            },
            issuerPrivateKey: issuer.key)
        return Issued(certificate: cert, key: key)
    }
}
