import Docuconf
import Foundation

enum LogLevel: String, ConfigEnum { case debug, info, warn, error }

struct DatabaseConfig: Sendable {
    @Env("database.url", "Primary Postgres connection string", .secret, .schemes("postgres", "postgresql"))
    var url: URL                                    // no default: required

    @Env("database.pool.size", "Connections in the pool", .range(1...100))
    var poolSize = 10
}

struct AppConfig: DocuconfConfig {
    @Env("http.port", "HTTP listen port", .range(1...65535))
    var port = 8080

    @Env("log.level", "Minimum log level")
    var logLevel = LogLevel.info

    @Env("request.timeout", "Upstream request timeout", .range(.seconds(1) ... .seconds(300)))
    var requestTimeout: Duration = .seconds(30)     // REQUEST_TIMEOUT=30, in seconds

    var database = DatabaseConfig()                 // a nested struct groups variables
}

Docuconf.exportIfRequested(AppConfig.self, name: "quickstart")  // the `docuconf-export` command, see below
let config = await Docuconf.loadOrExit(AppConfig.self)           // on a problem: prints them all, exits 1

print("listening on :\(config.port), log level \(config.logLevel), pool of \(config.database.poolSize)")
print(config)                                                    // secrets print as <redacted>
