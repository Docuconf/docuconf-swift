import Configuration
import Docuconf
import Foundation
import Testing

struct NarrowConfig: DocuconfConfig {
    @Env("shard.id", "Shard this instance owns") var shard: UInt16 = 3
    @Env("worker.count", description: "Background workers", .range(1..<65)) var workers: Int32 = 4
    @Env("listen.port", "HTTP listen port", .range(1..<65536)) var port = 8080
}

@Suite struct TypeRuleTests {
    @Test func narrowIntegersExportTheirRangeAndHalfOpenRangesWork() async throws {
        let d = try Declaration(NarrowConfig.self)
        let byName = Dictionary(uniqueKeysWithValues: d.vars.map { ($0.name, $0) })
        #expect(byName["SHARD_ID"]?.min == .int(0))
        #expect(byName["SHARD_ID"]?.max == .int(65535))
        #expect(byName["WORKER_COUNT"]?.min == .int(1))
        #expect(byName["WORKER_COUNT"]?.max == .int(64))
        #expect(byName["WORKER_COUNT"]?.description == "Background workers")
        #expect(byName["LISTEN_PORT"]?.max == .int(65535))

        let c = try await Docuconf.load(NarrowConfig.self, environment: ["SHARD_ID": "7", "WORKER_COUNT": "64"])
        #expect(c.shard == 7)
        #expect(c.workers == 64)
        do {
            _ = try await Docuconf.load(NarrowConfig.self, environment: ["SHARD_ID": "70000", "WORKER_COUNT": "65"])
            Issue.record("expected violations")
        } catch let e as ConfigurationError {
            #expect(e.violations.map(\.code) == [.outOfRange, .outOfRange])
        }
    }

}
