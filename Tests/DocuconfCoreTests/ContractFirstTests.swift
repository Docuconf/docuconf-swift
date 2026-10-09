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
        (.timespan, "00:00:01.5", .milliseconds(1500)), (.timespan, "1.00:00:00", .seconds(86400)),
        (.go, "-1m30s", .seconds(-90)), (.go, ".5s", .milliseconds(500)), (.go, "1.s", .seconds(1)), (.go, "1µs", .microseconds(1)),
    ])
    func parses(encoding: DurationEncoding, text: String, want: Duration) {
        #expect(encoding.parse(text) == want)
    }

    @Test(arguments: [
        (DurationEncoding.go, "PT90S"), (.go, "90"), (.go, ""), (.go, "1x"),
        (.iso8601, "1m30s"), (.iso8601, "PT"), (.iso8601, "P"), (.iso8601, "PT1.5M30S"), (.iso8601, "pt90s"),
        (.seconds, "90s"), (.seconds, "1e3"), (.seconds, "-5"), (.seconds, "1."), (.seconds, "0x10"),
        (.timespan, "1m30s"), (.timespan, "00:60:00"), (.timespan, "24:00:00"), (.timespan, "1:2:3:4"),
        // SPEC §5, strict: seconds are required, minutes and seconds take two digits, no sign, no weeks, no spaces.
        (.timespan, "02:30"), (.timespan, "00:1:30"), (.timespan, "00:01:3"), (.timespan, "-00:00:05"),
        (.iso8601, "P1W"), (.iso8601, "P1M"), (.iso8601, "-PT5S"), (.go, "1m 30s"), (.go, "5S"), (.go, "1d"), (.go, "5s\n"),
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

    @Test func loadsTypedValues() async throws {
        let doc = try ContractDocument(contract: Self.contract)
        let values = try await doc.load(environment: [
            "TIMEOUT": "PT1.5S", "HOSTS__0": "a", "HOSTS__1": "b", "SHARDS": "1;2", "TOKEN": "t0k3n", "UNRELATED": "x",
        ])
        #expect(values["PORT"] == .int(8080))
        #expect(values["TIMEOUT"] == .duration(.milliseconds(1500)))
        #expect(values["HOSTS"] == .stringList(["a", "b"]))
        #expect(values["SHARDS"] == .intList([1, 2]))
        #expect(values.json["TIMEOUT"] == "1s500ms")
    }

    @Test func reportsEveryViolation() async throws {
        let doc = try ContractDocument(contract: Self.contract)
        await #expect {
            try await doc.load(environment: ["PORT": "0", "SHARDS": "1;10", "TIMEOUT": "30s"])
        } throws: { error in
            let e = error as! ConfigurationError
            return Set(e.violations.map { "\($0.input)/\($0.code.rawValue)" })
                == ["PORT/out_of_range", "SHARDS/out_of_range", "TIMEOUT/invalid_type", "TOKEN/missing_required"]
        }
    }

    /// SPEC §5: an indexed list runs from `NAME__0` with no gap, and only decimal suffixes are items.
    @Test(arguments: [
        (["HOSTS__0": "a", "HOSTS__2": "c"], nil),
        (["HOSTS__1": "b"], nil),
        (["HOSTS__0": "a", "HOSTS__01": "b", "HOSTS__HOST": "x", "HOSTS__": "y"], ["a"]),
        (["HOSTS__0": "a", "HOSTS__1": "b", "HOSTS__10": "k"], nil),
    ] as [([String: String], [String]?)])
    func indexedListItems(env: [String: String], want: [String]?) async throws {
        let doc = try ContractDocument(contract: Self.contract)
        let env = env.merging(["TOKEN": "t"]) { a, _ in a }
        if let want {
            #expect(try await doc.load(environment: env)["HOSTS"] == .stringList(want))
        } else {
            await #expect {
                try await doc.load(environment: env)
            } throws: { error in
                (error as! ConfigurationError).violations.map { "\($0.input)/\($0.code.rawValue)" } == ["HOSTS/invalid_type"]
            }
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

    @Test func lengthLimits() async throws {
        let doc = try ContractDocument(contract: [
            "apiVersion": "docuconf.dev/v1alpha1", "kind": "ConfigContract", "metadata": ["name": "svc"],
            "vars": [
                "CALLBACK": ["type": "url", "description": "Callback URL", "schemes": ["https"], "maxLength": 24],
                "LIMITS": ["type": "json", "description": "Run limits", "maxLength": 16],
                "BRANCHES": ["type": "list", "description": "Branch codes", "items": "string", "itemMinLength": 2, "itemMaxLength": 4],
                "IDX": ["type": "list", "description": "Indexed codes", "items": "string", "encoding": "indexed", "itemMaxLength": 4],
            ],
        ])
        let values = try await doc.load(environment: [
            "CALLBACK": "https://例え.jp/日本語の道/一二三四", "LIMITS": #"{"n":"日本語の道路xy"}"#,
            "BRANCHES": "BE,ZÜ01,GE02", "IDX__0": "😀😀😀😀",
        ])
        #expect(values["BRANCHES"] == .stringList(["BE", "ZÜ01", "GE02"]))
        await #expect {
            try await doc.load(environment: [
                "CALLBACK": "https://a.example/runs/42", "LIMITS": #"{ "max": 123456 }"#, "BRANCHES": "BE,B",
                "IDX__0": "BE", "IDX__1": "GENEVA",
            ])
        } throws: { error in
            Set((error as! ConfigurationError).violations.map { "\($0.input)/\($0.code.rawValue)" })
                == ["CALLBACK/out_of_range", "LIMITS/out_of_range", "BRANCHES/out_of_range", "IDX/out_of_range"]
        }
    }

    @Test func rejectsItemLengthsOnIntLists() {
        let bad: JSONValue = ["vars": [
            "PORTS": ["type": "list", "description": "Ports to open", "items": "int", "itemMaxLength": 5],
            "LIMITS": ["type": "json", "description": "Run limits", "maxLength": 9, "default": ["a": "<&>"]],
        ]]
        #expect {
            try ContractDocument(contract: bad)
        } throws: { error in
            let p = (error as! DeclarationError).problems
            // {"a":"<&>"} is 11 characters: no HTML escaping.
            return p.contains("PORTS: itemMinLength and itemMaxLength apply only to lists of strings")
                && p.contains { $0.hasPrefix("LIMITS: default") && $0.hasSuffix("is 11 characters of JSON, longer than 9") }
        }
    }

    /// A contract exported from a Swift declaration, turned into JSON by `cue export`, loads in contract-first mode
    /// with the same defaults.
    @Test func roundTripsAnExportedContract() async throws {
        guard let json = try CueVet.export(Contract.cue(for: GatewayConfig.self, name: "gateway")) else {
            if CueVet.required { Issue.record("cue export required but cue or the meta-schema is missing") }
            return
        }
        // Only the variables: the file inputs are checked by the server SDK's tests.
        guard case .object(let members) = try JSONDecoder().decode(JSONValue.self, from: Data(json.utf8)) else {
            Issue.record("cue export is not an object")
            return
        }
        let doc = try ContractDocument(contract: .object(members.filter { $0.0 != "files" }))
        let d = try Declaration(GatewayConfig.self)
        #expect(doc.vars.map(\.name) == d.vars.map(\.name).sorted())
        let values = try await doc.load(environment: [
            "DATABASE_URL": "postgres://db/app", "API_TOKEN": "abcdefghijklmnop", "PARTNER_KEYSTORE_PASSWORD": "pw",
            "SHARD_IDS": "1,2", "REQUEST_TIMEOUT": "1.5",
        ])
        #expect(values["HTTP_PORT"] == .int(8080))
        #expect(values["SHARD_IDS"] == .intList([1, 2]))
        #expect(values["REQUEST_TIMEOUT"] == .duration(.milliseconds(1500)))
        #expect(values["KAFKA_BROKERS"] == .stringList(["kafka-0:9092", "kafka-1:9092"]))
        #expect(values.json["RATE_LIMIT"] == ["burst": 200, "requestsPerSecond": 100])
        await #expect(throws: ConfigurationError.self) {
            try await doc.load(environment: ["DATABASE_URL": "postgres://db/app", "API_TOKEN": "abcdefghijklmnop",
                                       "PARTNER_KEYSTORE_PASSWORD": "pw", "SHARD_IDS": "1024"])
        }
    }
}
