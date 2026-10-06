import Configuration
import CueTestSupport
import Docuconf
import Foundation
import Testing

/// The platform supplies most settings through a JSON overlay (SPEC §4.7); the secret comes from the env.
struct CatalogConfig: DocuconfConfig {
    static let overlays = [
        ConfigOverlay("platform", "Settings the platform manages", path: "/etc/catalog/overlay/catalog.json"),
    ]

    @Env("page.size", "Results per page", .range(1...200)) var pageSize = 20
    @Env("cache.ttl", "How long search results are cached") var cacheTTL: Duration = .seconds(60)
    @Env("search.url", "Search service", .schemes("https")) var searchURL: URL
    @Env("featured.categories", "Categories on the front page") var featured = ["books"]
    @Env("shard.ids", "Index shards to query") var shards: [Int] = [0]
    @Env("search.fuzzy", "Fuzzy matching") var fuzzy = false
    @Env("PORT", "HTTP listen port") var port = 8080
    @Env("database.password", "Database password", .secret) var dbPassword: String
}

/// The same settings in a YAML overlay.
struct YAMLCatalogConfig: DocuconfConfig {
    static let overlays = [
        ConfigOverlay("platform", "Settings the platform manages", path: "/etc/catalog/overlay/catalog.yaml"),
    ]

    @Env("page.size", "Results per page", .range(1...200)) var pageSize = 20
    @Env("cache.ttl", "How long search results are cached") var cacheTTL: Duration = .seconds(60)
    @Env("search.url", "Search service", .schemes("https")) var searchURL: URL
    @Env("featured.categories", "Categories on the front page") var featured = ["books"]
    @Env("search.fuzzy", "Fuzzy matching") var fuzzy = false
}

@Suite struct OverlayTests {
    static let overlayPath = "/etc/catalog/overlay/catalog.json"
    static let secretEnv = ["DATABASE_PASSWORD": "s3cr3t-pw"]

    /// A baked-in config file, read with swift-configuration's own file provider.
    func baseFile(_ box: Sandbox, _ json: String) async throws -> any ConfigProvider {
        try box.write("/app/config/catalog.json", json)
        return try await FileProvider<JSONSnapshot>(filePath: .init(box.root.path + "/app/config/catalog.json"))
    }

    @Test func overlaySitsBetweenFilesAndTheEnvironment() async throws {
        let box = try Sandbox(Self.secretEnv.merging(["SEARCH_URL": "https://env.example"]) { $1 })
        let base = try await baseFile(box, #"{"page": {"size": 10}, "cache": {"ttl": 120}, "search": {"url": "https://base.example"}}"#)
        try box.write(Self.overlayPath, #"{"page": {"size": 50}, "search": {"url": "https://overlay.example"}}"#)

        let c = try await Docuconf.load(CatalogConfig.self, files: [base], options: box.options())
        #expect(c.pageSize == 50, "the overlay wins over the baked-in file")
        #expect(c.cacheTTL == .seconds(120), "the baked-in file applies where the overlay is silent")
        #expect(c.searchURL.absoluteString == "https://env.example", "the environment wins over the overlay")
        #expect(c.port == 8080, "defaults apply where nothing is set")
    }

    @Test func aMissingOverlayIsFine() async throws {
        let box = try Sandbox(Self.secretEnv.merging(["SEARCH_URL": "https://env.example"]) { $1 })
        let base = try await baseFile(box, #"{"page": {"size": 10}}"#)
        let c = try await Docuconf.load(CatalogConfig.self, files: [base], options: box.options())
        #expect(c.pageSize == 10)
        #expect(box.terminationLog == nil)
    }

    @Test func overlayValuesAreValidatedLikeAnyOther() async throws {
        let box = try Sandbox(Self.secretEnv)
        try box.write(Self.overlayPath, #"{"page": {"size": 1000}, "search": {"url": "http://insecure.example"}, "shard": {"ids": [1, "two"]}}"#)
        let v = await box.violations(CatalogConfig.self)
        // A list mixing strings and numbers is not something swift-configuration can read: the whole file is refused.
        #expect(v.map(\.code) == [.fileMalformed, .missingRequired])

        try box.write(Self.overlayPath, #"{"page": {"size": 1000}, "search": {"url": "http://insecure.example"}}"#)
        let v2 = await box.violations(CatalogConfig.self)
        #expect(Dictionary(v2.map { ($0.input, $0.code) }) { a, _ in a } == ["PAGE_SIZE": .outOfRange, "SEARCH_URL": .invalidScheme])
        #expect(v2.first { $0.input == "PAGE_SIZE" }?.message.contains("1000") == true)
    }

    @Test func aMalformedOverlayIsReportedWithEverythingElse() async throws {
        let box = try Sandbox(Self.secretEnv.merging(["PORT": "eighty"]) { $1 })
        try box.write(Self.overlayPath, "{not json")
        let v = await box.violations(CatalogConfig.self)
        #expect(v.map(\.input) == ["platform", "SEARCH_URL", "PORT"])
        #expect(v.map(\.code) == [.fileMalformed, .missingRequired, .invalidType])
        #expect(v[0].message.hasPrefix("overlay \(box.root.path)\(Self.overlayPath) is not valid JSON"))
        #expect(box.terminationLog?.contains("platform [file_malformed]") == true)
    }

    @Test func yamlOverlay() async throws {
        let box = try Sandbox()
        try box.write("/etc/catalog/overlay/catalog.yaml", """
            page:
              size: 50
            cache:
              ttl: "90"
            search:
              url: https://search.internal
              fuzzy: true
            featured:
              categories:
                - books
                - games
            """)
        let c = try await box.load(YAMLCatalogConfig.self)
        #expect(c.pageSize == 50)
        #expect(c.cacheTTL == .seconds(90))
        #expect(c.searchURL.absoluteString == "https://search.internal")
        #expect(c.fuzzy == true)
        #expect(c.featured == ["books", "games"])
    }

    @Test func anOverlayInTheAppsOwnDirectoryIsRefused() async throws {
        let box = try Sandbox(Self.secretEnv.merging(["SEARCH_URL": "https://env.example"]) { $1 })
        var options = box.options()
        options.appDirectory = box.root.path + "/etc/catalog/overlay"
        try FileManager.default.createDirectory(atPath: options.appDirectory!, withIntermediateDirectories: true)
        do {
            _ = try await Docuconf.load(CatalogConfig.self, options: options)
            Issue.record("expected a DeclarationError")
        } catch let e as DeclarationError {
            #expect(e.problems.count == 1)
            #expect(e.problems[0].hasPrefix("overlay platform: /etc/catalog/overlay/catalog.json is in the app's own directory"))
        }
    }

    @Test func composeYourOwnReader() async throws {
        let box = try Sandbox(Self.secretEnv)
        let base = try await baseFile(box, #"{"page": {"size": 10}, "search": {"url": "https://base.example"}}"#)
        try box.write(Self.overlayPath, #"{"search": {"url": "https://overlay.example"}}"#)
        let options = box.options()
        let reader = ConfigReader(providers: [EnvironmentVariablesProvider(environmentVariables: box.env)]
            + (try await Docuconf.overlayProviders(for: CatalogConfig.self, options: options))
            + [base])
        let c = try await Docuconf.load(CatalogConfig.self, from: reader, options: options)
        #expect(c.pageSize == 10)
        #expect(c.searchURL.absoluteString == "https://overlay.example")

        try box.write(Self.overlayPath, "[]")
        await #expect(throws: ConfigurationError.self) {
            _ = try await Docuconf.overlayProviders(for: CatalogConfig.self, options: options)
        }
    }

    // End to end: the platform renders the overlay from the exported contract with the CUE meta-schema
    // (`contract.#Render`), and the app loads the rendered file.
    @Test func anOverlayRenderedByThePlatformLoadsInTheApp() async throws {
        let contract = try Docuconf.contract(for: CatalogConfig.self, name: "catalog", package: "svc")
        guard let file = try CueVet.renderOverlay(contract, overlay: "platform", fileName: "catalog.json", overlayValues: """
            PAGE_SIZE: 50
            CACHE_TTL: "1m30s"
            SEARCH_URL: "https://search.internal"
            FEATURED_CATEGORIES: ["books", "games"]
            SHARD_IDS: [3, 4]
            SEARCH_FUZZY: true
            PORT: 9090
            """, values: #"DATABASE_PASSWORD: secretKeyRef: {name: "catalog-db", key: "password"}"#) else {
            if CueVet.required { Issue.record("cue or the meta-schema is missing") }
            return
        }
        #expect(file.contains(#""ttl": "90""#), "a duration is rendered in the variable's encoding (seconds)")

        let box = try Sandbox(Self.secretEnv)
        try box.write(Self.overlayPath, file)
        let c = try await box.load(CatalogConfig.self)
        #expect(c.pageSize == 50)
        #expect(c.cacheTTL == .seconds(90))
        #expect(c.searchURL.absoluteString == "https://search.internal")
        #expect(c.featured == ["books", "games"])
        #expect(c.shards == [3, 4])
        #expect(c.fuzzy == true)
        #expect(c.port == 9090)
        #expect(c.dbPassword == "s3cr3t-pw")
    }

    @Test func aYAMLOverlayRenderedByThePlatformLoadsInTheApp() async throws {
        let contract = try Docuconf.contract(for: YAMLCatalogConfig.self, name: "catalog", package: "svc")
        guard let file = try CueVet.renderOverlay(contract, overlay: "platform", fileName: "catalog.yaml", overlayValues: """
            PAGE_SIZE: 50
            CACHE_TTL: "1m30s"
            SEARCH_URL: "https://search.internal"
            FEATURED_CATEGORIES: ["books", "games"]
            SEARCH_FUZZY: true
            """) else {
            if CueVet.required { Issue.record("cue or the meta-schema is missing") }
            return
        }
        let box = try Sandbox()
        try box.write("/etc/catalog/overlay/catalog.yaml", file)
        let c = try await box.load(YAMLCatalogConfig.self)
        #expect(c.pageSize == 50)
        #expect(c.cacheTTL == .seconds(90))
        #expect(c.searchURL.absoluteString == "https://search.internal")
        #expect(c.featured == ["books", "games"])
        #expect(c.fuzzy == true)
    }
}
