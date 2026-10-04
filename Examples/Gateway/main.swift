// A minimal service using docuconf. Run it with:
//
//   swift run GatewayExample docuconf-export --out contract.cue   # write the contract, read no environment
//   DOCUCONF_FILE_ROOT=Examples/Gateway/dev-root DATABASE_URL=postgres://localhost/gw swift run GatewayExample
//
// A real service would hand `config` to Hummingbird or Vapor; this one prints what it loaded.
import Configuration
import Docuconf
import Foundation

enum LogLevel: String, ConfigEnum {
    case debug, info, warn, error
}

struct Route: Decodable, Sendable {
    var prefix: String
    var upstream: URL
}

struct Routes: Decodable, Sendable {
    var routes: [Route]
}

struct GatewayConfig: DocuconfConfig {
    @Env("http.port", "HTTP listen port", .range(1...65535))
    var port = 8443

    @Env("database.url", "Primary Postgres connection string", .secret, .schemes("postgres", "postgresql"))
    var databaseURL: URL

    @Env("log.level", "Minimum log level")
    var logLevel = LogLevel.info

    @Env("request.timeout", "Upstream request timeout", .range(.seconds(1) ... .seconds(300)))
    var requestTimeout: Duration = .seconds(30)

    @FileInput("routes", "Routing table: path prefixes and their upstreams",
               path: "/etc/gateway/routes/routes.json", .reload(.watch))
    var routes: ConfigFile<Routes>

    @FileInput("tls", "Certificate the gateway serves HTTPS with", path: "/etc/gateway/tls",
               .dnsNames("gateway.internal"), .minRemaining(.seconds(7 * 24 * 3600)))
    var tls: TLSKeyPair?
}

Docuconf.exportIfRequested(GatewayConfig.self, name: "gateway")

do {
    let config = try await Docuconf.load(GatewayConfig.self)
    print("listening on :\(config.port), log level \(config.logLevel), timeout \(config.requestTimeout)")
    print("routes: \(config.routes.routes.map(\.prefix))")
    print("TLS: \(config.tls.map { "\($0)" } ?? "off")")
} catch {
    Docuconf.printToStandardError("\(error)")
    exit(1)
}
