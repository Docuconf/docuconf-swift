import CueTestSupport
import DocuconfCore
import Foundation
import Testing

@Suite struct WireDurationTests {
    @Test(arguments: [
        (DurationEncoding.go, "1h2m3s4ms", Duration.milliseconds(3_723_004)), (.go, "1.5h", .seconds(5400)),
        (.go, "0", .zero), (.go, "250us", .microseconds(250)), (.go, "-1s", .seconds(-1)),
        (.iso8601, "PT90S", .seconds(90)), (.iso8601, "PT1.5S", .milliseconds(1500)), (.iso8601, "PT0S", .zero),
        (.iso8601, "P1DT2H30M", .seconds(95_400)), (.iso8601, "PT0.001S", .milliseconds(1)),
        (.seconds, "90", .seconds(90)), (.seconds, "0.25", .milliseconds(250)), (.seconds, "180000", .seconds(180_000)),
        (.timespan, "00:01:30", .seconds(90)), (.timespan, "1.02:03:04.5", .milliseconds(93_784_500)),
        (.timespan, "00:00:01.5", .milliseconds(1500)), (.timespan, "02:30", .seconds(9000)),
    ])
    func parses(encoding: DurationEncoding, text: String, want: Duration) {
        #expect(encoding.parse(text) == want)
    }

    @Test(arguments: [
        (DurationEncoding.go, "PT90S"), (.go, "90"), (.go, ""), (.go, "1x"),
        (.iso8601, "1m30s"), (.iso8601, "PT"), (.iso8601, "P"), (.iso8601, "PT1.5M30S"), (.iso8601, "pt90s"),
        (.seconds, "90s"), (.seconds, "1e3"), (.seconds, "-5"), (.seconds, "1."), (.seconds, "0x10"),
        (.timespan, "1m30s"), (.timespan, "00:60:00"), (.timespan, "24:00:00"), (.timespan, "1:2:3:4"),
    ])
    func rejects(encoding: DurationEncoding, text: String) {
        #expect(encoding.parse(text) == nil)
    }
}

@Suite struct ContractFirstTests {
    static let contract: JSONValue = [
        "apiVersion": "docuconf.dev/v1alpha1", "kind": "ConfigContract", "metadata": ["name": "svc"],
        "vars": [
            "PORT": ["type": "int", "description": "Port to listen on", "min": 1, "max": 65535, "default": 8080],
            "TIMEOUT": ["type": "duration", "description": "Request timeout", "encoding": "iso8601", "default": "30s"],
            "HOSTS": ["type": "list", "description": "Allowed hosts", "items": "string", "encoding": "indexed"],
            "SHARDS": ["type": "list", "description": "Shard ids", "items": "int", "separator": ";", "itemMax": 9],
            "TOKEN": ["type": "string", "description": "API token", "secret": true, "required": true],
        ],
    ]

    @Test func loadsTypedValues() throws {
        let doc = try ContractDocument(contract: Self.contract)
        let values = try doc.load(environment: [
            "TIMEOUT": "PT1.5S", "HOSTS__0": "a", "HOSTS__1": "b", "SHARDS": "1;2", "TOKEN": "t0k3n", "UNRELATED": "x",
        ])
        #expect(values["PORT"] == .int(8080))
        #expect(values["TIMEOUT"] == .duration(.milliseconds(1500)))
        #expect(values["HOSTS"] == .stringList(["a", "b"]))
        #expect(values["SHARDS"] == .intList([1, 2]))
        #expect(values.json["TIMEOUT"] == "1s500ms")
    }

    @Test func reportsEveryViolation() throws {
        let doc = try ContractDocument(contract: Self.contract)
        #expect {
            try doc.load(environment: ["PORT": "0", "SHARDS": "1;10", "TIMEOUT": "30s"])
        } throws: { error in
            let e = error as! ConfigurationError
            return Set(e.violations.map { "\($0.input)/\($0.code.rawValue)" })
                == ["PORT/out_of_range", "SHARDS/out_of_range", "TIMEOUT/invalid_type", "TOKEN/missing_required"]
        }
    }

    @Test func rejectsABrokenContract() {
        let bad: JSONValue = ["vars": [
            "X": ["type": "list", "description": "String items", "items": "string", "itemMin": 0],
            "Y": ["type": "decimal", "description": "Unknown type"],
        ]]
        #expect {
            try ContractDocument(contract: bad)
        } throws: { error in
            let p = (error as! DeclarationError).problems
            return p.contains("X: itemMin and itemMax apply only to lists of integers") && p.contains("Y: unknown type \"decimal\"")
        }
    }

    /// A contract exported from a Swift declaration, turned into JSON by `cue export`, loads in contract-first mode
    /// with the same defaults.
    @Test func roundTripsAnExportedContract() throws {
        guard let json = try CueVet.export(Contract.cue(for: GatewayConfig.self, name: "gateway")) else {
            if CueVet.required { Issue.record("cue export required but cue or the meta-schema is missing") }
            return
        }
        let doc = try ContractDocument(json: Data(json.utf8))
        let d = try Declaration(GatewayConfig.self)
        #expect(doc.vars.map(\.name) == d.vars.map(\.name).sorted())
        let values = try doc.load(environment: [
            "DATABASE_URL": "postgres://db/app", "API_TOKEN": "abcdefghijklmnop", "PARTNER_KEYSTORE_PASSWORD": "pw",
            "SHARD_IDS": "1,2", "REQUEST_TIMEOUT": "1.5",
        ])
        #expect(values["HTTP_PORT"] == .int(8080))
        #expect(values["SHARD_IDS"] == .intList([1, 2]))
        #expect(values["REQUEST_TIMEOUT"] == .duration(.milliseconds(1500)))
        #expect(values["KAFKA_BROKERS"] == .stringList(["kafka-0:9092", "kafka-1:9092"]))
        #expect(values.json["RATE_LIMIT"] == ["burst": 200, "requestsPerSecond": 100])
        #expect(throws: ConfigurationError.self) {
            try doc.load(environment: ["DATABASE_URL": "postgres://db/app", "API_TOKEN": "abcdefghijklmnop",
                                       "PARTNER_KEYSTORE_PASSWORD": "pw", "SHARD_IDS": "1024"])
        }
    }
}
