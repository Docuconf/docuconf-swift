// snippet:hummingbird
import Configuration
import Docuconf
import Foundation
import Hummingbird
import Logging
import ServiceLifecycle

struct Greeting: Decodable, Sendable { var text: String }

struct HelloConfig: DocuconfConfig {
    @Env("http.host", "Address to listen on") var host = "0.0.0.0"
    @Env("http.port", "HTTP listen port", .range(1...65535)) var port = 8080
    @Env("database.url", "Primary Postgres connection string", .secret, .schemes("postgres")) var databaseURL: URL
    @FileInput("greeting", "Greeting served on /", path: "/etc/hello/greeting.json", .reload(.watch))
    var greeting: ConfigFile<Greeting>
}

/// Keeps the `.reload(.watch)` promise: applies changes to the greeting while the app runs.
struct GreetingReloader: Service {
    let config: HelloConfig
    let logger: Logger

    func run() async {
        for await change in config.$greeting.changes(every: .seconds(5)).cancelOnGracefulShutdown() {
            switch change {
            case .updated(let greeting): logger.info("greeting is now \(greeting.text)")
            case .rejected(let violations): logger.error("kept the old greeting: \(violations)")
            }
        }
    }
}

Docuconf.exportIfRequested(HelloConfig.self, name: "hello")

// One ConfigReader for docuconf and the rest of the app.
let reader = ConfigReader(provider: EnvironmentVariablesProvider())
let config = await Docuconf.loadOrExit(HelloConfig.self, from: reader)
let logger = Logger(label: "hello")

let router = Router()
router.get("/") { _, _ in config.greeting.text }  // always the latest content that passed its checks
router.get("/healthz") { _, _ in "ok" }

var app = Application(
    router: router,
    configuration: .init(address: .hostname(config.host, port: config.port)),
    logger: logger
)
app.addServices(GreetingReloader(config: config, logger: logger))
try await app.runService()
// snippet:end
