import Docuconf
import Foundation
import Testing

enum Currency: String, Codable, CaseIterable, Sendable {
    case eur = "EUR"
    case usd = "USD"
}

struct Route: Decodable, Sendable {
    var match: String
    var upstream: URL
}

struct Routes: Decodable, Sendable, ValidatedConfig {
    var items: [Route]
    func validate() -> [String] {
        items.isEmpty ? ["$.items must not be empty"] : []
    }
}

struct Settings: Decodable, Sendable {
    var currency: Currency
    var limits: [String: Int]
}

struct FilesConfig: DocuconfConfig {
    @Env("ks.password", "Partner keystore password", .secret) var ksPassword: String?
    @FileInput("routes", "Routing table", path: "/etc/svc/routes/routes.json", .pathEnv("ROUTES_FILE"), .maxSize(4096), .reload(.watch))
    var routes: ConfigFile<Routes>
    @FileInput("settings", "Currency and limits", path: "/etc/svc/settings/settings.yaml") var settings: ConfigFile<Settings>?
    @FileInput("license", "Licence key", path: "/etc/svc/license/license.key", .pattern("^[A-Z0-9-]{8,}\\n?$"), .maxLength(64)) var license: TextFile?
    @FileInput("geoip", "GeoIP database", path: "/etc/svc/geoip/geo.mmdb", .maxSize(16)) var geoip: BinaryFile?
}

let routesJSON = #"{"items":[{"match":"/api","upstream":"http://api:8080"}]}"#

@Suite struct FileTests {
    @Test func loadsEveryFileType() async throws {
        let box = try Sandbox(["KS_PASSWORD": "changeit"])
        try box.write("/etc/svc/routes/routes.json", routesJSON)
        try box.write("/etc/svc/settings/settings.yaml", "currency: EUR\nlimits:\n  orders: 10\n")
        try box.write("/etc/svc/license/license.key", "ABCD-1234-EFGH\n")
        try box.write("/etc/svc/geoip/geo.mmdb", Data([1, 2, 3]))
        let c = try await box.load(FilesConfig.self)
        #expect(c.routes.items.first?.upstream.host == "api")
        #expect(c.routes.path == box.root.path + "/etc/svc/routes/routes.json")
        #expect(c.settings?.currency == .eur)
        #expect(c.settings?.limits == ["orders": 10])
        #expect(c.license?.text == "ABCD-1234-EFGH\n")
        #expect(c.geoip?.data == Data([1, 2, 3]))
    }

    @Test func optionalFilesMayBeAbsent() async throws {
        let box = try Sandbox()
        try box.write("/etc/svc/routes/routes.json", routesJSON)
        let c = try await box.load(FilesConfig.self)
        #expect(c.settings == nil)
        #expect(c.license == nil)
    }

    @Test func missingRequiredFile() async throws {
        let box = try Sandbox()
        let v = await box.violations(FilesConfig.self)
        #expect(v.map(\.code) == [.fileMissing])
        #expect(v[0].input == "routes")
    }

    @Test func pathEnvAndFileRoot() async throws {
        // A path from pathEnv is prefixed with DOCUCONF_FILE_ROOT too.
        let box = try Sandbox(["ROUTES_FILE": "/mnt/elsewhere/routes.json"])
        try box.write("/mnt/elsewhere/routes.json", routesJSON)
        let c = try await box.load(FilesConfig.self)
        #expect(c.routes.path == box.root.path + "/mnt/elsewhere/routes.json")
        #expect(c.$routes.resolvedPath == c.routes.path)
    }

    @Test func malformedConfig() async throws {
        let box = try Sandbox()
        try box.write("/etc/svc/routes/routes.json", #"{"items": [}"#)
        try box.write("/etc/svc/settings/settings.yaml", "currency: [EUR\n")
        let v = await box.violations(FilesConfig.self)
        #expect(v.map(\.code) == [.fileMalformed, .fileMalformed])
        #expect(v.map(\.input) == ["routes", "settings"])
    }

    @Test func schemaViolation() async throws {
        let box = try Sandbox()
        try box.write("/etc/svc/routes/routes.json", #"{"items":[{"match":"/api"}]}"#)
        try box.write("/etc/svc/settings/settings.yaml", "currency: GBP\nlimits: {}\n")
        let v = await box.violations(FilesConfig.self)
        #expect(v.map(\.code) == [.schemaMismatch, .schemaMismatch])
        #expect(v[0].message.contains("$.items[0].upstream is required"))
    }

    @Test func validatedConfig() async throws {
        let box = try Sandbox()
        try box.write("/etc/svc/routes/routes.json", #"{"items":[]}"#)
        let v = await box.violations(FilesConfig.self)
        #expect(v == [Violation(.schemaMismatch, "routes", "$.items must not be empty")])
    }

    @Test func tooLarge() async throws {
        let box = try Sandbox()
        try box.write("/etc/svc/routes/routes.json", routesJSON)
        try box.write("/etc/svc/geoip/geo.mmdb", Data(count: 17))
        #expect(await box.violations(FilesConfig.self).map(\.code) == [.fileTooLarge])
    }

    @Test func textConstraints() async throws {
        let box = try Sandbox()
        try box.write("/etc/svc/routes/routes.json", routesJSON)
        try box.write("/etc/svc/license/license.key", "abc")
        #expect(await box.violations(FilesConfig.self).map(\.code) == [.patternMismatch])
    }

    @Test func unreadableFile() async throws {
        guard getuid() != 0 else { return }  // root reads everything
        let box = try Sandbox()
        try box.write("/etc/svc/routes/routes.json", routesJSON)
        let url = box.root.appendingPathComponent("etc/svc/routes/routes.json")
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: url.path)
        let v = await box.violations(FilesConfig.self)
        #expect(v.map(\.code) == [.fileUnreadable])
        #expect(v[0].message.contains("fsGroup"))
    }

    @Test(.timeLimit(.minutes(1))) func watchReloadsChangedContent() async throws {
        let box = try Sandbox()
        try box.write("/etc/svc/routes/routes.json", routesJSON)
        let c = try await box.load(FilesConfig.self)
        var changes = c.$routes.changes(every: .milliseconds(20)).makeAsyncIterator()

        try box.write("/etc/svc/routes/routes.json", #"{"items":[{"match":"/v2","upstream":"http://v2:8080"}]}"#)
        guard case .updated(let routes)? = await changes.next() else {
            Issue.record("expected an update")
            return
        }
        #expect(routes.items[0].match == "/v2")
        #expect(c.routes.items[0].match == "/v2", "the property returns the new value")

        try box.write("/etc/svc/routes/routes.json", "{")
        guard case .rejected(let v)? = await changes.next() else {
            Issue.record("expected a rejection")
            return
        }
        #expect(v.map(\.code) == [.fileMalformed])
        #expect(c.routes.items[0].match == "/v2", "bad content is not applied")
    }

    @Test func varsAndFilesFailTogether() async throws {
        struct Both: DocuconfConfig {
            @Env("http.port", "HTTP listen port") var port = 8080
            @Env("database.url", "Primary database", .secret) var databaseURL: URL
            @FileInput("routes", "Routing table", path: "/etc/svc/routes/routes.json") var routes: ConfigFile<Routes>
            @FileInput("license", "Licence key", path: "/etc/svc/license/license.key") var license: TextFile
        }
        let box = try Sandbox(["HTTP_PORT": "eighty"])
        try box.write("/etc/svc/routes/routes.json", "[")
        let v = await box.violations(Both.self)
        #expect(v.map(\.code) == [.invalidType, .missingRequired, .fileMalformed, .fileMissing])
        #expect(box.terminationLog?.contains("docuconf: 4 configuration problems") == true)
    }
}
