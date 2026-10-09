import Docuconf
import Foundation
import Testing

struct WebhookConfig: DocuconfConfig {
    @Env("webhook.keys", "Keys that verify webhook signatures", .keyLength(8...64))
    var webhookKeys: KeySet
    @Env("api.keys", "Keys callers present", .keys(1...3), .separator(";"))
    var apiKeys: KeySet?
}

let keyA = "key-aaaa-0001"
let keyB = "key-bbbb-0002"

@Suite struct KeySetTests {
    @Test func loadsKeysInOrder() async throws {
        let box = try Sandbox(["WEBHOOK_KEYS": "\(keyA),\(keyB)", "API_KEYS": " one;two "])
        let c = try await box.load(WebhookConfig.self)
        #expect(c.webhookKeys.keys == [keyA, keyB])
        #expect(c.apiKeys?.keys == [" one", "two "])  // never trimmed
    }

    @Test func isAlwaysSecretAndRedacted() async throws {
        let d = try Declaration(WebhookConfig.self)
        #expect(d.vars.allSatisfy { $0.secret })
        let box = try Sandbox(["WEBHOOK_KEYS": "\(keyA),\(keyB)"])
        let c = try await box.load(WebhookConfig.self)
        for text in [String(describing: c), String(reflecting: c), "\(c.webhookKeys)", String(reflecting: c.webhookKeys)] {
            #expect(!text.contains(keyA) && !text.contains(keyB), "\(text)")
        }
        var dumped = ""
        dump(c.webhookKeys, to: &dumped)
        #expect(!dumped.contains(keyA))
    }

    @Test func containsAndVerify() {
        let set = KeySet([keyA, keyB])
        #expect(set.contains(keyA))
        #expect(set.contains(keyB))
        #expect(!set.contains("key-aaaa-000"))
        #expect(!set.contains(keyA + "x"))
        #expect(!set.contains(""))
        var tried: [String] = []
        let ok = set.verify { key in
            tried.append(String(decoding: key, as: UTF8.self))
            return key == Data(keyA.utf8)
        }
        #expect(ok)
        #expect(tried == [keyA, keyB], "every key is tried, even after a match")
        #expect(!set.verify { _ in false })
    }

    @Test(arguments: [
        ("\(keyA),", "out_of_range"),  // a stray separator: an empty key
        ("k3y-x", "out_of_range"),
        ("\(keyA),\(keyB),key-cccc-0003", "too_many_items"),
        ("vault:secret/data/payments#webhook", "invalid_type"),
    ])
    func violationsNeverHoldAKey(value: String, code: String) async throws {
        let box = try Sandbox(["WEBHOOK_KEYS": value])
        let v = await box.violations(WebhookConfig.self)
        #expect(v.map(\.code.rawValue) == [code])
        for part in value.split(separator: ",") where !part.isEmpty {
            #expect(!v.description.contains(part))
            #expect(!(box.terminationLog ?? "").contains(part))
        }
    }

    @Test func missingIsRequired() async throws {
        let v = try await Sandbox().violations(WebhookConfig.self)
        #expect(v.map(\.code) == [.missingRequired])
    }

    @Test func exportsAsKeySet() throws {
        let text = try Contract.cue(for: WebhookConfig.self, name: "webhooks")
        #expect(text.contains("type:        \"keySet\"") || text.contains("type: \"keySet\""))
        #expect(text.contains("separator: \";\""))
        #expect(text.contains("keyMinLength: 8") && text.contains("keyMaxLength: 64"))
        #expect(text.contains("minKeys: 1") && text.contains("maxKeys: 3"))
    }

    @Test func badBoundsAreDeclarationErrors() {
        struct Bad: DocuconfConfig {
            @Env("keys", "Keys with bad bounds", .keys(0...1), .keyLength(0...4)) var keys: KeySet?
        }
        #expect(throws: DeclarationError.self) { try Declaration(Bad.self) }
        struct Backwards: DocuconfConfig {
            @Env("keys", "Keys with bad bounds", .minKeys(3)) var keys: KeySet?
        }
        #expect(throws: DeclarationError.self) { try Declaration(Backwards.self) }
    }
}

@Suite struct DeprecatedRuleTests {
    struct Old: DocuconfConfig {
        @Env("port", "Port to listen on") var port = 8080
        @Env("old.token", "Token of the retired API", .secret, .deprecated("The billing API no longer takes a token"))
        var oldToken: String?
        @Env("old.port", "Old name of the port", .deprecated("Use PORT instead", replacedBy: "PORT"))
        var oldPort: Int?
    }

    @Test func warnsWithTheNameAndMessageNeverTheValue() async throws {
        let box = try Sandbox(["OLD_TOKEN": "tok-s3cr3t-value", "OLD_PORT": "9090"])
        let c = try await box.load(Old.self)
        #expect(c.oldPort == 9090)
        let warnings = box.warnings.filter { $0.contains("deprecated") }
        #expect(warnings.count == 2)
        #expect(warnings.contains { $0.contains("OLD_TOKEN") && $0.contains("The billing API no longer takes a token") })
        #expect(warnings.contains { $0.contains("OLD_PORT") && $0.contains("Use PORT instead") })
        #expect(!warnings.joined().contains("tok-s3cr3t-value") && !warnings.joined().contains("9090"))
    }

    @Test func unsetDeprecatedInputsDoNotWarn() async throws {
        let box = try Sandbox()
        _ = try await box.load(Old.self)
        #expect(!box.warnings.contains { $0.contains("deprecated") })
    }

    @Test func aRequiredInputCannotBeDeprecated() {
        struct Required: DocuconfConfig {
            @Env("token", "Token of the retired API", .deprecated("Going away")) var token: String
        }
        #expect { try Declaration(Required.self) } throws: { error in
            (error as? DeclarationError)?.problems.contains { $0.contains("a required input cannot be deprecated") } ?? false
        }
    }

    @Test func theMessageIsNotBlankAndAtMost500Characters() {
        struct Blank: DocuconfConfig {
            @Env("old", "An old setting here", .deprecated("  \n")) var old: Int?
        }
        #expect(throws: DeclarationError.self) { try Declaration(Blank.self) }
        struct Long: DocuconfConfig {
            @Env("old", "An old setting here", .deprecated(String(repeating: "é", count: 501))) var old: Int?
        }
        #expect(throws: DeclarationError.self) { try Declaration(Long.self) }
        struct AtLimit: DocuconfConfig {
            @Env("old", "An old setting here", .deprecated(String(repeating: "é", count: 500))) var old: Int?
        }
        #expect(throws: Never.self) { try Declaration(AtLimit.self) }
    }

    @Test func aRequiredFileInputCannotBeDeprecated() {
        struct Files: DocuconfConfig {
            @FileInput("licence", "Licence key file", path: "/etc/app/licence/licence.key", .deprecated("Going away"))
            var licence: TextFile
        }
        #expect(throws: DeclarationError.self) { try Declaration(Files.self) }
    }
}

@Suite struct StrictParsingTests {
    struct Strict: DocuconfConfig {
        @Env("flag", "A switch to test") var flag: Bool?
        @Env("count", "A count to test") var count: Int?
        @Env("ratio", "A ratio to test") var ratio: Double?
        @Env("names", "Names to test") var names: [String]?
    }

    /// Declaration mode parses environment strings with the SPEC §5 rules, not swift-configuration's.
    @Test(arguments: [
        ("FLAG", "1"), ("FLAG", "yes"), ("FLAG", "on"), ("FLAG", "t"), ("FLAG", " true"), ("FLAG", "true\n"),
        ("COUNT", "0x10"), ("COUNT", "1_000"), ("COUNT", "1e3"), ("COUNT", " 5"), ("COUNT", "+-5"),
        ("RATIO", ".5"), ("RATIO", "5."), ("RATIO", "inf"), ("RATIO", "nan"), ("RATIO", "0x1p4"), ("RATIO", "1e400"), ("RATIO", "0,5"),
    ])
    func rejects(name: String, value: String) async throws {
        let v = try await Sandbox([name: value]).violations(Strict.self)
        #expect(v.map(\.code) == [.invalidType], "\(name)=\(value)")
    }

    @Test func accepts() async throws {
        let c = try await Sandbox(["FLAG": "tRuE", "COUNT": "+007", "RATIO": "25e-2", "NAMES": "a, b ,,c"]).load(Strict.self)
        #expect(c.flag == true)
        #expect(c.count == 7)
        #expect(c.ratio == 0.25)
        #expect(c.names == ["a", " b ", "", "c"])
    }
}

@Suite struct ContractFirstFileTests {
    static let contract: JSONValue = [
        "apiVersion": "docuconf.dev/v1alpha1", "kind": "ConfigContract", "metadata": ["name": "svc"],
        "vars": [
            "APP_ENV": ["type": "string", "description": "Profile selector", "default": "Production"],
            "PAGE_SIZE": ["type": "int", "description": "Items per page", "min": 1, "default": 10, "configKey": "Catalog:PageSize"],
            "KEYS": ["type": "keySet", "description": "Keys that verify signatures", "secret": true, "keyMinLength": 4],
        ],
        "files": [
            "settings": ["type": "config", "format": "toml", "description": "Settings file", "path": "/etc/svc/settings/s.toml",
                         "schema": ["type": "object", "required": ["name"]]],
        ],
        "profiles": ["selector": "APP_ENV", "default": "Production", "defaults": ["Production": ["PAGE_SIZE": 20]]],
        "overlays": ["platform": ["format": "yaml", "path": "/etc/svc/overlay/o.yaml", "keySeparator": ":"]],
    ]

    @Test func layersFilesAndKeySets() async throws {
        let box = try Sandbox(["KEYS": "abcd,efgh"])
        try box.write("/etc/svc/settings/s.toml", "name = \"orders\"\n[limits]\nburst = 10\n")
        let doc = try ContractDocument(contract: Self.contract)
        var values = try await doc.load(environment: box.env, support: DocuconfFileSupport())
        #expect(values["PAGE_SIZE"] == .int(20))
        #expect(values["KEYS"] == .stringList(["abcd", "efgh"]))
        #expect(values.files["settings"] == .config(["name": "orders", "limits": ["burst": 10]]))

        try box.write("/etc/svc/overlay/o.yaml", "Catalog:\n  PageSize: 30\n")
        values = try await doc.load(environment: box.env, support: DocuconfFileSupport())
        #expect(values["PAGE_SIZE"] == .int(30))

        var env = box.env
        env["PAGE_SIZE"] = "40"
        values = try await doc.load(environment: env, support: DocuconfFileSupport())
        #expect(values["PAGE_SIZE"] == .int(40))
    }

    @Test func foundationSupportReadsJSONAndTOMLButNotYAML() async throws {
        let box = try Sandbox(["KEYS": "abcd"])
        try box.write("/etc/svc/settings/s.toml", "name = \"orders\"\n")
        try box.write("/etc/svc/overlay/o.yaml", "Catalog:\n  PageSize: 30\n")
        let doc = try ContractDocument(contract: Self.contract)
        await #expect {
            try await doc.load(environment: box.env)
        } throws: { error in
            (error as? ConfigurationError)?.violations.map { "\($0.input)/\($0.code.rawValue)" } == ["platform/file_malformed"]
        }
    }
}
