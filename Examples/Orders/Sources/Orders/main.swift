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

    @Env("database.url", "Postgres connection string for the orders database", .secret, .schemes("postgres"), .maxLength(2048))
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

    // A key set (always secret): one or two keys, so a key can be rotated without turning webhooks away
    // (Webhook.swift checks a signature against every key). The generated docs print the rotation steps.
    @Env("webhook.keys", """
        Keys that verify the signature on incoming payment webhooks

        A webhook is accepted when it is signed with any key in the set, so the key can be rotated without
        turning webhooks away. Each key is 32 to 256 characters, so an empty or truncated key fails at boot.
        Without this variable, the service rejects every webhook.
        """, .keyLength(32...256))
    var webhookKeys: KeySet?
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
    "webhookKeys": "***",
]
let configBody = try JSONSerialization.data(withJSONObject: configJSON, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])

print("orders listening on :\(config.port)")
try HTTPServer(port: config.port).run { request in
    switch (request.method, request.path) {
    case ("GET", "/healthz"): (200, "text/plain", Data("ok".utf8))
    case ("GET", "/config"): (200, "application/json", configBody)
    // Payment webhooks, signed with any key in WEBHOOK_KEYS.
    case ("POST", "/webhooks/payments"):
        Webhook.verify(keys: config.webhookKeys ?? KeySet([]), body: request.body, signature: request.headers["x-signature"] ?? "")
            ? (204, "text/plain", Data())
            : (401, "text/plain", Data("bad signature".utf8))
    case (_, "/healthz"), (_, "/config"), (_, "/webhooks/payments"): (405, "text/plain", Data("method not allowed".utf8))
    default: (404, "text/plain", Data("not found".utf8))
    }
}
