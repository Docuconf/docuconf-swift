#if TLS
import Docuconf
import Foundation
import Testing

struct TLSConfig: DocuconfConfig {
    @FileInput("serving-tls", "Serving certificate", path: "/etc/svc/tls",
               .dnsNames("svc.internal", "api.example.com"), .keyAlgorithms(.ecdsa, .ed25519),
               .minRemaining(.seconds(720 * 3600)), .requireCA)
    var tls: TLSKeyPair
}

@Suite struct TLSTests {
    func sandbox(cert: TestPKI.Issued, key: String? = nil, ca: TestPKI.Issued?, extraChain: String = "") throws -> Sandbox {
        let box = try Sandbox()
        try box.write("/etc/svc/tls/tls.crt", cert.certificatePEM + extraChain)
        try box.write("/etc/svc/tls/tls.key", key ?? cert.keyPEM)
        if let ca { try box.write("/etc/svc/tls/ca.crt", ca.certificatePEM) }
        return box
    }

    @Test func validKeyPair() async throws {
        let ca = try TestPKI.ca()
        let leaf = try TestPKI.leaf(dnsNames: ["svc.internal", "*.example.com"], issuer: ca)
        let box = try sandbox(cert: leaf, ca: ca)
        let c = try await box.load(TLSConfig.self)
        #expect(String(decoding: c.tls.certificatePEM, as: UTF8.self) == leaf.certificatePEM)
        #expect(c.tls.caPEM != nil)
        #expect(c.tls.directory.hasSuffix("/etc/svc/tls"))
        #expect(!"\(c.tls)".contains("PRIVATE KEY"))
    }

    @Test func ed25519IsAllowed() async throws {
        let ca = try TestPKI.ca()
        let leaf = try TestPKI.leaf(dnsNames: ["svc.internal", "api.example.com"], issuer: ca, keyKind: .ed25519)
        #expect(try await sandbox(cert: leaf, ca: ca).violations(TLSConfig.self).isEmpty)
    }

    @Test func expiringSoon() async throws {
        let ca = try TestPKI.ca()
        let leaf = try TestPKI.leaf(dnsNames: ["svc.internal", "api.example.com"], issuer: ca, notAfter: Date() + 10 * 86400)
        let v = try await sandbox(cert: leaf, ca: ca).violations(TLSConfig.self)
        #expect(v.map(\.code) == [.certificateExpiring])
        #expect(v[0].message.contains("sooner than the required 720h"))
    }

    @Test func expired() async throws {
        let ca = try TestPKI.ca()
        let leaf = try TestPKI.leaf(dnsNames: ["svc.internal", "api.example.com"], issuer: ca, notBefore: Date() - 20 * 86400, notAfter: Date() - 86400)
        #expect(try await sandbox(cert: leaf, ca: ca).violations(TLSConfig.self).map(\.code) == [.certificateInvalid])
    }

    @Test func dnsMismatch() async throws {
        let ca = try TestPKI.ca()
        // A wildcard covers exactly one label: *.internal does not cover api.example.com, *.example.com
        // would not cover a.b.example.com.
        let leaf = try TestPKI.leaf(dnsNames: ["*.internal"], issuer: ca)
        let v = try await sandbox(cert: leaf, ca: ca).violations(TLSConfig.self)
        #expect(v == [Violation(.certificateNameMismatch, "serving-tls", "the certificate does not cover api.example.com")])
    }

    @Test func keyMismatch() async throws {
        let ca = try TestPKI.ca()
        let leaf = try TestPKI.leaf(dnsNames: ["svc.internal", "api.example.com"], issuer: ca)
        let other = try TestPKI.leaf(dnsNames: ["other"], issuer: ca)
        let v = try await sandbox(cert: leaf, key: other.keyPEM, ca: ca).violations(TLSConfig.self)
        #expect(v.map(\.code) == [.keyMismatch])
        #expect(!v[0].message.contains("PRIVATE KEY"))
        // SPEC §11.2 item 5: a tls.key with no PEM key at all is file_malformed.
        let garbage = try await sandbox(cert: leaf, key: "not a key", ca: ca).violations(TLSConfig.self)
        #expect(garbage.map(\.code) == [.fileMalformed])
    }

    @Test func disallowedKeyAlgorithm() async throws {
        let ca = try TestPKI.ca()
        let leaf = try TestPKI.leaf(dnsNames: ["svc.internal", "api.example.com"], issuer: ca, keyKind: .rsa)
        let v = try await sandbox(cert: leaf, ca: ca).violations(TLSConfig.self)
        #expect(v == [Violation(.certificateInvalid, "serving-tls", "the certificate uses a RSA key; allowed: ECDSA, Ed25519")])
    }

    @Test func brokenChain() async throws {
        let ca = try TestPKI.ca()
        let stranger = try TestPKI.ca("another CA")
        let leaf = try TestPKI.leaf(dnsNames: ["svc.internal", "api.example.com"], issuer: ca)
        let v = try await sandbox(cert: leaf, ca: stranger).violations(TLSConfig.self)
        #expect(v == [Violation(.certificateInvalid, "serving-tls", "the certificate does not chain to a certificate in ca.crt")])
    }

    @Test func missingCAFile() async throws {
        let ca = try TestPKI.ca()
        let leaf = try TestPKI.leaf(dnsNames: ["svc.internal", "api.example.com"], issuer: ca)
        let v = try await sandbox(cert: leaf, ca: nil).violations(TLSConfig.self)
        #expect(v.map(\.code) == [.fileMissing])
        #expect(v[0].message.hasSuffix("/etc/svc/tls/ca.crt does not exist"))
    }

    @Test func missingDirectory() async throws {
        let v = try await Sandbox().violations(TLSConfig.self)
        #expect(v.map(\.code) == [.fileMissing])
    }

    @Test func notACertificate() async throws {
        let ca = try TestPKI.ca()
        let box = try Sandbox()
        try box.write("/etc/svc/tls/tls.crt", "hello")
        try box.write("/etc/svc/tls/tls.key", "hello")
        try box.write("/etc/svc/tls/ca.crt", ca.certificatePEM)
        // No PEM certificate at all is file_malformed; a PEM certificate that does not parse is certificate_invalid.
        #expect(await box.violations(TLSConfig.self).map(\.code) == [.fileMalformed])
        try box.write("/etc/svc/tls/tls.crt", "-----BEGIN CERTIFICATE-----\nAAAA\n-----END CERTIFICATE-----\n")
        #expect(await box.violations(TLSConfig.self).map(\.code) == [.certificateInvalid])
    }

    @Test func everyProblemTogether() async throws {
        let ca = try TestPKI.ca()
        let leaf = try TestPKI.leaf(dnsNames: ["nope.internal"], issuer: ca, keyKind: .rsa, notAfter: Date() + 86400)
        let other = try TestPKI.leaf(dnsNames: ["x"], issuer: ca)
        let v = try await sandbox(cert: leaf, key: other.keyPEM, ca: ca).violations(TLSConfig.self)
        #expect(v.map(\.code) == [.keyMismatch, .certificateExpiring, .certificateNameMismatch, .certificateNameMismatch, .certificateInvalid])
    }
}
#endif
