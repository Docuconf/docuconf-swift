import DocuconfCore
import Foundation

// A declaration that uses every variable type and every file input type. Its export is the golden file.

enum LogLevel: String, ConfigEnum {
    case debug, info, warn, error
}

enum Currency: String, Codable, CaseIterable, Sendable {
    case eur = "EUR"
    case usd = "USD"
}

struct RateLimit: JSONConfigValue, Equatable {
    var requestsPerSecond: Int
    var burst: Int
    var exempt: [String]?
}

struct Route: Decodable, Sendable {
    var match: String
    var upstream: URL
    var methods: [String]?
    var timeoutSeconds: Double?
}

struct Routes: Decodable, Sendable {
    var items: [Route]
    var fallback: URL?
}

struct Settings: Decodable, Sendable {
    var currency: Currency
    var limits: [String: Int]
    var flags: Flags

    struct Flags: Decodable, Sendable {
        var strict: Bool
    }
}

struct GatewayConfig: DocuconfConfig {
    @Env("http.port", "HTTP listen port", .range(1...65535))
    var port = 8080

    @Env("database.url", "Primary Postgres connection string", .secret, .schemes("postgres", "postgresql"), .group("database"))
    var databaseURL: URL

    @Env("log.level", "Minimum log level")
    var logLevel = LogLevel.info

    @Env("request.timeout", "Upstream request timeout", .range(.seconds(1) ... .seconds(300)))
    var requestTimeout: Duration = .seconds(30)

    @Env("upstream.timeout", "Old name for the upstream timeout", .deprecated("Use REQUEST_TIMEOUT", replacedBy: "REQUEST_TIMEOUT"))
    var upstreamTimeout: Duration?

    @Env("sampling.ratio", "Fraction of requests to trace", .range(0.0...1.0))
    var samplingRatio = 0.25

    @Env("tracing.enabled", "Whether to export traces")
    var tracingEnabled = false

    @Env("kafka.brokers", "Kafka brokers to connect to", .items(1...5))
    var kafkaBrokers = ["kafka-0:9092", "kafka-1:9092"]

    @Env("retry.backoffMs", "Retry backoff steps in milliseconds", .maxItems(10))
    var retryBackoff: [Int]?

    @Env("api.token", "Token for the partner API", .secret, .length(16...128), .pattern("^[A-Za-z0-9_-]+$"))
    var apiToken: String

    @Env("cloud.region", "Cloud region the gateway runs in", .pattern("^[a-z]+-[a-z]+-[0-9]$"), .group("cloud"), .examples("eu-west-1", "us-east-2"))
    var region = "eu-west-1"

    @Env("rate.limit", "Per-client rate limit")
    var rateLimit = RateLimit(requestsPerSecond: 100, burst: 200, exempt: nil)

    @Env("partner.keystorePassword", "Password for the partner keystore", .secret)
    var partnerKeystorePassword: String

    @Env("otel.endpoint", "OTLP endpoint; tracing export is off when unset", .schemes("http", "https"))
    var otelEndpoint: URL?

    @FileInput("routes", "Routing table: path prefixes and their upstreams", path: "/etc/gateway/routes/routes.json",
               .pathEnv("ROUTES_FILE"), .reload(.watch), .maxSize(65536))
    var routes: ConfigFile<Routes>

    @FileInput("settings", "Currency, limits and strictness", path: "/etc/gateway/settings/settings.yaml")
    var settings: ConfigFile<Settings>?

    @FileInput("serving-tls", "Certificate the gateway serves HTTPS with", path: "/etc/gateway/tls",
               .dnsNames("gateway.internal", "api.example.com"), .keyAlgorithms(.ecdsa, .rsa),
               .minRemaining(.seconds(720 * 3600)), .requireCA, .reload(.watch))
    var servingTLS: TLSKeyPair

    @FileInput("trusted-cas", "Private CAs to trust for upstream calls", path: "/etc/gateway/ca/bundle.pem",
               .pathEnv("SSL_CERT_FILE"), .minCertificates(2))
    var trustedCAs: CABundle?

    @FileInput("partner", "Client certificate for the partner API", path: "/etc/gateway/partner/keystore.p12",
               .passwordVar("PARTNER_KEYSTORE_PASSWORD"))
    var partner: Keystore?

    @FileInput("license", "Licence key", path: "/etc/gateway/license/license.key", .pattern("^[A-Z0-9-]{8,}\\n?$"), .secret)
    var license: TextFile

    @FileInput("geoip", "GeoIP database", path: "/etc/gateway/geoip/GeoLite2-City.mmdb", .maxSize(100_000_000))
    var geoip: BinaryFile?
}
