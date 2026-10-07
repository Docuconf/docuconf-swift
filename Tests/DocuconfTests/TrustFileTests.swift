#if TLS
import Docuconf
import Foundation
import Testing

// CA bundles and keystores are checked with swift-certificates and swift-crypto, built with the TLS trait.
struct TrustConfig: DocuconfConfig {
    @Env("ks.password", "Partner keystore password", .secret) var ksPassword: String?
    @FileInput("routes", "Routing table", path: "/etc/svc/routes/routes.json") var routes: ConfigFile<Routes>
    @FileInput("cas", "Private CAs to trust", path: "/etc/svc/ca/bundle.pem", .minCertificates(2)) var cas: CABundle?
    @FileInput("partner", "Partner keystore", path: "/etc/svc/partner/ks.p12", .passwordVar("KS_PASSWORD")) var partner: Keystore?
    @FileInput("legacy", "Legacy keystore", path: "/etc/svc/legacy/ks.jks", .passwordVar("KS_PASSWORD")) var legacy: Keystore?
}

@Suite struct TrustFileTests {
    @Test func loadsBundlesAndKeystores() async throws {
        let box = try Sandbox(["KS_PASSWORD": "changeit"])
        let ca1 = try TestPKI.ca("CA one")
        let ca2 = try TestPKI.ca("CA two")
        try box.write("/etc/svc/routes/routes.json", routesJSON)
        try box.write("/etc/svc/ca/bundle.pem", ca1.certificatePEM + ca2.certificatePEM)
        try box.write("/etc/svc/partner/ks.p12", Sandbox.fixture("keystore.p12"))
        try box.write("/etc/svc/legacy/ks.jks", Sandbox.fixture("keystore.jks"))
        let c = try await box.load(TrustConfig.self)
        #expect(c.cas?.certificateCount == 2)
        #expect(c.partner?.data.isEmpty == false)
        #expect(c.legacy?.data.isEmpty == false)
    }

    @Test func caBundleCounts() async throws {
        let box = try Sandbox()
        try box.write("/etc/svc/routes/routes.json", routesJSON)
        try box.write("/etc/svc/ca/bundle.pem", try TestPKI.ca().certificatePEM)
        let v = await box.violations(TrustConfig.self)
        #expect(v.map(\.code) == [.fileMalformed])
        #expect(v[0].message.contains("holds 1 certificate; at least 2 required"))
        try box.write("/etc/svc/ca/bundle.pem", "-----BEGIN CERTIFICATE-----\nAAAA\n-----END CERTIFICATE-----\n")
        #expect(await box.violations(TrustConfig.self).map(\.code) == [.fileMalformed])
    }

    @Test func keystorePasswords() async throws {
        for (fixture, path) in [("keystore.p12", "/etc/svc/partner/ks.p12"), ("keystore-legacy.p12", "/etc/svc/partner/ks.p12"), ("keystore.jks", "/etc/svc/legacy/ks.jks")] {
            let good = try Sandbox(["KS_PASSWORD": "changeit"])
            try good.write("/etc/svc/routes/routes.json", routesJSON)
            try good.write(path, Sandbox.fixture(fixture))
            #expect(await good.violations(TrustConfig.self).isEmpty, "\(fixture) opens with the right password")

            let bad = try Sandbox(["KS_PASSWORD": "wrong-password"])
            try bad.write("/etc/svc/routes/routes.json", routesJSON)
            try bad.write(path, Sandbox.fixture(fixture))
            let v = await bad.violations(TrustConfig.self)
            #expect(v.map(\.code) == [.keystoreUnreadable], "\(fixture) rejects a wrong password")
            #expect(!v.description.contains("wrong-password"))
        }
        let garbage = try Sandbox(["KS_PASSWORD": "changeit"])
        try garbage.write("/etc/svc/routes/routes.json", routesJSON)
        try garbage.write("/etc/svc/partner/ks.p12", Data("not a keystore".utf8))
        #expect(await garbage.violations(TrustConfig.self).map(\.code) == [.keystoreUnreadable])
    }

}
#endif
