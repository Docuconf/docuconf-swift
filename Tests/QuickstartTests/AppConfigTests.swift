// snippet:testing
@testable import Quickstart
import Docuconf
import Testing

@Suite struct AppConfigTests {
    let valid = ["DATABASE_URL": "postgres://app@localhost/app"]

    @Test func defaults() async throws {
        let config = try await Docuconf.load(AppConfig.self, environment: valid)
        #expect(config.port == 8080)
        #expect(config.database.poolSize == 10)
    }

    @Test func rejectsPortZero() async throws {
        let error = await #expect(throws: ConfigurationError.self) {
            try await Docuconf.load(AppConfig.self, environment: valid.merging(["HTTP_PORT": "0"]) { $1 })
        }
        #expect(error?.violations.map(\.code) == [.outOfRange])
    }

    @Test func contractListsEveryVariable() throws {
        let names = try Declaration(AppConfig.self).vars.map(\.name)
        #expect(names.contains("DATABASE_POOL_SIZE"))
    }
}
// snippet:end
