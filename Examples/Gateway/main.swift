// The gateway from the README's reference sections: variables, a watched config file and a TLS key pair.
// TLS checks need the package's TLS trait. Run it with:
//
//   swift run GatewayExample docuconf-export --out contract.cue   # write the contract, read no environment
//   Examples/Gateway/make-dev-tls.sh                               # a dev certificate under dev-root
//   DOCUCONF_FILE_ROOT=Examples/Gateway/dev-root DATABASE_URL=postgres://localhost/gw swift run --traits TLS GatewayExample
//
// Add --watch to keep running and print each change to dev-root/etc/gateway/routes/routes.json.
import Configuration
import Docuconf
import Foundation

// snippet:gateway-config
enum LogLevel: String, ConfigEnum { case debug, info, warn, error }

struct Routes: Decodable, Sendable {
    var routes: [Route]
    struct Route: Decodable, Sendable { var prefix: String; var upstream: URL }
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
    var routes: ConfigFile<Routes>             // JSON Schema derived from Routes

    @FileInput("tls", "Certificate the gateway serves HTTPS with", path: "/etc/gateway/tls",
               .dnsNames("gateway.internal"), .keyAlgorithms(.ecdsa), .minRemaining(.seconds(30 * 24 * 3600)))
    var tls: TLSKeyPair                        // needs the TLS trait
}
// snippet:end

Docuconf.exportIfRequested(GatewayConfig.self, name: "gateway")

let config = await Docuconf.loadOrExit(GatewayConfig.self)
print("listening on :\(config.port), log level \(config.logLevel), timeout \(config.requestTimeout)")
print("routes: \(config.routes.routes.map(\.prefix))")
print("TLS: \(config.tls)")

if CommandLine.arguments.contains("--watch") {
    // snippet:reload
    for await change in config.$routes.changes(every: .seconds(10)) {
        switch change {
        case .updated(let routes): print("new routes: \(routes.routes.map(\.prefix))")  // passed every boot check
        case .rejected(let violations): print("kept the old routes: \(violations)")      // the old value stays
        }
    }
    // snippet:end
}
