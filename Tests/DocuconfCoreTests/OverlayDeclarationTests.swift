import CueTestSupport
import DocuconfCore
import Foundation
import Testing

/// A service whose platform supplies most settings through a JSON overlay (SPEC §4.7).
struct CatalogConfig: DocuconfConfig {
    static let overlays = [
        ConfigOverlay("platform", "Settings the platform manages", path: "/etc/catalog/overlay/catalog.json"),
    ]

    @Env("page.size", "Results per page", .range(1...200)) var pageSize = 20
    @Env("cache.ttl", "How long search results are cached") var cacheTTL: Duration = .seconds(60)
    @Env("search.url", "Search service", .schemes("https")) var searchURL: URL
    @Env("featured.categories", "Categories on the front page") var featured = ["books"]
    @Env("PORT", "HTTP listen port") var port = 8080
    @Env("rate.limit", "Per-client rate limit") var rateLimit = RateLimit(requestsPerSecond: 10, burst: 20)
    @Env("database.password", "Database password", .secret) var dbPassword: String
}

@Suite struct OverlayDeclarationTests {
    func problems(_ overlays: [ConfigOverlay], files: [FileSpec] = []) -> [String] {
        Declaration.validate(vars: [], files: files, overlays: overlays).problems
    }

    @Test func catalogIsValid() throws {
        let d = try Declaration(CatalogConfig.self)
        #expect(d.overlays.map(\.name) == ["platform"])
        #expect(d.overlays[0].format == .json)
        #expect(d.overlays[0].keySeparator == ".")
        #expect(d.overlays[0].reload == .restart)
    }

    @Test func formatFromExtension() {
        #expect(ConfigOverlay("a", path: "/etc/a/o.yaml").format == .yaml)
        #expect(ConfigOverlay("a", path: "/etc/a/o.yml").format == .yaml)
        #expect(ConfigOverlay("a", path: "/etc/a/o.json").format == .json)
        #expect(ConfigOverlay("a", path: "/etc/a/o.conf", format: .yaml).problems.isEmpty)
        #expect(problems([ConfigOverlay("a", path: "/etc/a/o.conf")]) == [
            "overlay a: cannot tell the format of /etc/a/o.conf from its extension; pass format:",
        ])
    }

    @Test func watchIsRejected() {
        // docuconf reads variables once at boot; it does not claim a reload it would not perform.
        let p = problems([ConfigOverlay("platform", path: "/etc/svc/overlay/svc.json", reload: .watch)])
        #expect(p.count == 1)
        #expect(p[0].hasPrefix("overlay platform: reload: watch is not supported"))
    }

    @Test func declarationMistakes() {
        let tls = FileSpec(name: "tls", type: .tls, description: "Serving certificate", path: "/etc/svc/tls")
        let p = problems([
            ConfigOverlay("Platform", path: "/etc/svc/overlay/a.json"),
            ConfigOverlay("dup", "Short", path: "/etc/svc/one/a.json"),
            ConfigOverlay("dup", "abc", path: "/etc/svc/two/a.json"),
            ConfigOverlay("relative", path: "etc/svc/a.json"),
            ConfigOverlay("reserved", path: "/app/appsettings.json"),
            ConfigOverlay("clash", path: "/etc/svc/tls/overlay.json"),
            ConfigOverlay("toml", path: "/etc/svc/toml/a.toml", format: .toml),
        ], files: [tls])
        #expect(p.contains { $0.hasPrefix("overlay Platform: overlay names must be DNS labels") })
        #expect(p.contains("overlay dup: declared twice"))
        #expect(p.contains("overlay dup: description must be at least 5 characters"))
        #expect(p.contains { $0.hasPrefix("overlay relative: path etc/svc/a.json must be absolute") })
        #expect(p.contains { $0.hasPrefix("overlay reserved: would be mounted at /app") })
        #expect(p.contains("overlay clash: shares mount directory /etc/svc/tls with tls"))
        #expect(p.contains { $0.hasPrefix("overlay toml: TOML overlays are not supported") })
        #expect(p.count == 7)
    }

    @Test func exportsOverlaysAndConfigKeys() throws {
        let text = try Contract.cue(for: CatalogConfig.self, name: "catalog")
        #expect(text.contains("""
            \toverlays: {
            \t\tplatform: {
            \t\t\tdescription: "Settings the platform manages"
            \t\t\tformat: "json"
            \t\t\tpath: "/etc/catalog/overlay/catalog.json"
            \t\t\tkeySeparator: "."
            \t\t\treload: "restart"
            \t\t}
            \t}
            """))
        let d = try Declaration(CatalogConfig.self)
        let keys = Dictionary(uniqueKeysWithValues: d.vars.map { v in
            (v.name, Contract.fields(v, overlays: true).first { $0.0 == "configKey" }?.1)
        })
        #expect(keys["PAGE_SIZE"] == "page.size")
        // Written even when it equals the variable name, so the platform may put it in the overlay.
        #expect(keys["PORT"] == "PORT")
        // swift-configuration's file snapshots split an object into keys, so a json value stays in the env.
        #expect(keys["RATE_LIMIT"] == .some(nil))
        // Without overlays, the contract is unchanged.
        #expect(Contract.fields(d.vars.first { $0.name == "PORT" }!).allSatisfy { $0.0 != "configKey" })
    }

    @Test func exportWithOverlayPassesCueVet() throws {
        let text = try Contract.cue(for: CatalogConfig.self, name: "catalog")
        switch try CueVet.vet(text, package: "catalog") {
        case .passed: break
        case .failed(let output): Issue.record("cue vet failed:\n\(output)")
        case .skipped(let why): if CueVet.required { Issue.record("cue vet required but skipped: \(why)") }
        }
    }

    @Test func platformCannotPutJSONOrSecretsInTheOverlay() throws {
        // The meta-schema refuses overlay values the app could not, or must not, read from the overlay.
        let text = try Contract.cue(for: CatalogConfig.self, name: "catalog", package: "svc")
        let required = #"SEARCH_URL: "https://search.internal""#
        let env = #"DATABASE_PASSWORD: secretKeyRef: {name: "catalog-db", key: "password"}"#
        func render(_ overlay: String, _ values: String = env) throws -> String? {
            try CueVet.renderOverlay(text, overlay: "platform", fileName: "catalog.json", overlayValues: overlay, values: values)
        }
        guard try render(required) != nil else {
            if CueVet.required { Issue.record("cue or the meta-schema is missing") }
            return
        }
        for (overlay, values) in [
            (required + "\nRATE_LIMIT: {requestsPerSecond: 1, burst: 2}", env),
            (required + "\nDATABASE_PASSWORD: \"x\"", ""),
            (required + "\nPAGE_SIZE: 500", env),
        ] {
            #expect(throws: CueVet.RenderError.self, "\(overlay)") { try render(overlay, values) }
        }
    }
}
