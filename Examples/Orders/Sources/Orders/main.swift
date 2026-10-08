import Docuconf
import Foundation

enum LogLevel: String, ConfigEnum {
    case debug, info, warn, error
}

// Each key is a swift-configuration key; the environment variable is its upper-cased form (`log.level` is LOG_LEVEL).
// A property with no initial value is required.
struct OrdersConfig: DocuconfConfig {
    @Env("port", "HTTP listen port", .range(1...65535))
    var port = 8080

    @Env("log.level", "Minimum log level")
    var logLevel = LogLevel.info

    @Env("database.url", "Postgres connection string for the orders database", .secret, .schemes("postgres"))
    var databaseURL: URL

    @Env("allowed.origins", "Origins allowed to call the API (CORS)", .minItems(1))
    var allowedOrigins = ["http://localhost:3000"]

    // Durations are read as a number of seconds (REQUEST_TIMEOUT=30); the contract holds "30s".
    @Env("request.timeout", "Timeout for one request", .range(.seconds(1) ... .seconds(300)))
    var requestTimeout: Duration = .seconds(30)

    // A description may be a whole doc comment: its first paragraph is the description, the rest the details.
    @Env("worker.count", """
        Number of background order workers

        Each worker takes one order at a time from the queue and holds one database connection, so keep this
        at or below the pool size:

        - one connection per worker;
        - plus one for the HTTP handlers.
        """, .range(1...64))
    var workerCount = 4
}

// `orders docuconf-export --out contract.cue` writes the contract and exits without reading the environment.
Docuconf.exportIfRequested(OrdersConfig.self, name: "orders")

// Reads the environment. On a problem it prints every violation at once (also to /dev/termination-log) and exits 1.
let config = await Docuconf.loadOrExit(OrdersConfig.self)

let configJSON: [String: Any] = [
    "port": config.port,
    "logLevel": config.logLevel.rawValue,
    "databaseURL": "***",
    "allowedOrigins": config.allowedOrigins,
    "requestTimeout": GoDuration.format(config.requestTimeout),
    "workerCount": config.workerCount,
]
let configBody = try JSONSerialization.data(withJSONObject: configJSON, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])

print("orders listening on :\(config.port)")
try HTTPServer(port: config.port).run { path in
    switch path {
    case "/healthz": (200, "text/plain", Data("ok".utf8))
    case "/config": (200, "application/json", configBody)
    default: (404, "text/plain", Data("not found".utf8))
    }
}
