// snippet:vapor
import Docuconf
import Vapor

struct HelloConfig: DocuconfConfig {
    @Env("port", "HTTP listen port", .range(1...65535)) var port = 8080
    @Env("database.url", "Primary Postgres connection string", .secret, .schemes("postgres")) var databaseURL: URL
    @Env("greeting", "Greeting served on /", .length(1...200)) var greeting = "hello"
}

extension Application {
    private struct HelloConfigKey: StorageKey { typealias Value = HelloConfig }

    /// The validated configuration, for route handlers: `req.application.config.greeting`.
    var config: HelloConfig {
        get { storage[HelloConfigKey.self]! }
        set { storage[HelloConfigKey.self] = newValue }
    }
}

@main enum Entrypoint {
    static func main() async throws {
        Docuconf.exportIfRequested(HelloConfig.self, name: "hello")  // before Vapor parses the arguments

        var env = try Environment.detect()
        try LoggingSystem.bootstrap(from: &env)
        // Application.make loads .env and .env.<environment> into the process environment,
        // so load the configuration after it, or local values from .env are not seen.
        let app = try await Application.make(env)
        app.config = await Docuconf.loadOrExit(HelloConfig.self)
        app.http.server.configuration.port = app.config.port

        app.get { req in req.application.config.greeting }
        app.get("healthz") { _ in "ok" }

        do {
            try await app.execute()
        } catch {
            app.logger.report(error: error)
            try? await app.asyncShutdown()
            throw error
        }
        try await app.asyncShutdown()
    }
}
// snippet:end
