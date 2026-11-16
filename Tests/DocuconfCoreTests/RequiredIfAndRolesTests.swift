import DocuconfCore
import Foundation
import Testing

/// `requiredIf` (SPEC §4.2.1), `roles` (SPEC §4.9) and `includes` (SPEC §4.8) in contract-first mode.
@Suite struct RequiredIfTests {
    static let contract: JSONValue = [
        "apiVersion": "docuconf.dev/v1alpha1", "kind": "ConfigContract", "metadata": ["name": "relay"],
        "vars": [
            "APP_ENV": ["type": "string", "description": "Which profile file the app loads", "default": "development"],
            "TLS_ENABLED": ["type": "bool", "description": "Serve HTTPS instead of HTTP", "default": false],
            "TLS_CLIENT_CA_SUBJECT": [
                "type": "string", "description": "Subject of the CA that signs client certificates",
                "requiredIf": ["TLS_ENABLED": true],
            ],
            "LOG_FORMAT": ["type": "enum", "description": "Log output format", "values": ["text", "json"], "default": "text"],
            "LOG_SCHEMA_URL": [
                "type": "url", "description": "JSON schema the structured logs follow", "requiredIf": ["LOG_FORMAT": "json"],
            ],
            "PORT": ["type": "int", "description": "Port to listen on", "default": 8080],
            "ACME_EMAIL": ["type": "string", "description": "Contact address for certificate renewal", "requiredIf": ["PORT": 443]],
        ],
        "files": [
            "allowlist": [
                "type": "text", "description": "Client names allowed over TLS", "path": "/etc/relay/allowlist/allow.txt",
                "requiredIf": ["TLS_ENABLED": true],
            ],
        ],
        "profiles": ["selector": "APP_ENV", "default": "development", "defaults": ["production": ["TLS_ENABLED": true]]],
    ]

    /// An empty directory as `DOCUCONF_FILE_ROOT`, so no test reads the machine's own files.
    static func emptyRoot() throws -> String {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("docuconf-required-if-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root.path
    }

    static func violations(_ doc: ContractDocument, _ env: [String: String]) async throws -> [Violation] {
        let root = try emptyRoot()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let environment = env.merging(["DOCUCONF_FILE_ROOT": root]) { a, _ in a }
        let result: Result<ContractValues, ConfigurationError>
        do {
            result = .success(try await doc.load(environment: environment))
        } catch {
            result = .failure(error)
        }
        switch result {
        case .success: return []
        case .failure(let e): return e.violations
        }
    }

    @Test func readsConditions() throws {
        let doc = try ContractDocument(contract: Self.contract)
        #expect(doc.conditions["TLS_CLIENT_CA_SUBJECT"] == RequiredIf(variable: "TLS_ENABLED", value: .bool(true)))
        #expect(doc.conditions["LOG_SCHEMA_URL"] == RequiredIf(variable: "LOG_FORMAT", value: .string("json")))
        #expect(doc.conditions["ACME_EMAIL"] == RequiredIf(variable: "PORT", value: .int(443)))
        #expect(doc.conditions["allowlist"] == RequiredIf(variable: "TLS_ENABLED", value: .bool(true)))
        #expect(doc.conditions["PORT"] == nil)
    }

    @Test func conditionsOffLeaveTheInputsOptional() async throws {
        #expect(try await Self.violations(ContractDocument(contract: Self.contract), [:]).isEmpty)
    }

    /// The message names the condition, its value as JSON: a string is quoted.
    @Test func messagesNameTheCondition() async throws {
        let found = try await Self.violations(ContractDocument(contract: Self.contract), [
            "TLS_ENABLED": "true", "LOG_FORMAT": "json", "PORT": "443",
        ])
        let byInput = Dictionary(found.map { ($0.input, $0) }, uniquingKeysWith: { a, _ in a })
        #expect(found.count == 4)
        #expect(byInput["TLS_CLIENT_CA_SUBJECT"]?.code == .missingRequired)
        #expect(byInput["TLS_CLIENT_CA_SUBJECT"]?.message == "is required when TLS_ENABLED is true")
        #expect(byInput["LOG_SCHEMA_URL"]?.message == #"is required when LOG_FORMAT is "json""#)
        #expect(byInput["ACME_EMAIL"]?.message == "is required when PORT is 443")
        #expect(byInput["allowlist"]?.code == .fileMissing)
        #expect(byInput["allowlist"]?.message.hasSuffix("/etc/relay/allowlist/allow.txt does not exist, and is required when TLS_ENABLED is true") == true)
    }

    /// The condition compares the loaded value: here the selected profile's default.
    @Test func aProfileTurnsAConditionOn() async throws {
        let found = try await Self.violations(ContractDocument(contract: Self.contract), ["APP_ENV": "production"])
        #expect(Set(found.map { "\($0.input)/\($0.code.rawValue)" }) == ["TLS_CLIENT_CA_SUBJECT/missing_required", "allowlist/file_missing"])
        // The environment beats the profile.
        #expect(try await Self.violations(ContractDocument(contract: Self.contract), ["APP_ENV": "production", "TLS_ENABLED": "false"]).isEmpty)
    }

    @Test func setInputsSatisfyTheirConditions() async throws {
        let doc = try ContractDocument(contract: Self.contract)
        let root = try Self.emptyRoot()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let values = try await doc.load(environment: [
            "LOG_FORMAT": "json", "LOG_SCHEMA_URL": "https://logs.example.com/v1.json", "DOCUCONF_FILE_ROOT": root,
        ])
        #expect(values["LOG_SCHEMA_URL"] == .url("https://logs.example.com/v1.json"))
    }

    /// A condition variable with a violation of its own has no value, so it makes nothing required.
    @Test func anInvalidConditionVariableMakesNothingRequired() async throws {
        let found = try await Self.violations(ContractDocument(contract: Self.contract), ["TLS_ENABLED": "yes"])
        #expect(found.map { "\($0.input)/\($0.code.rawValue)" } == ["TLS_ENABLED/invalid_type"])
    }

    @Test func conditionDescriptions() {
        #expect(RequiredIf(variable: "TLS_ENABLED", value: .bool(false)).description == "TLS_ENABLED is false")
        #expect(RequiredIf(variable: "LOG_FORMAT", value: .string("json")).description == #"LOG_FORMAT is "json""#)
        #expect(RequiredIf(variable: "PORT", value: .int(443)).description == "PORT is 443")
        // A boolean condition never holds for an integer, nor a string one for a number.
        #expect(!RequiredIf(variable: "X", value: .bool(true)).holds(for: .int(1)))
        #expect(!RequiredIf(variable: "X", value: .string("1")).holds(for: .int(1)))
        #expect(RequiredIf(variable: "X", value: .string("json")).holds(for: .enumCase("json")))
        #expect(!RequiredIf(variable: "X", value: .int(1)).holds(for: nil))
    }

    /// The reader's refusals (SPEC §4.2.1).
    @Test(arguments: [
        (["requiredIf": ["A": true, "B": true]] as JSONValue, "X: requiredIf must name one variable and its value: {VAR: value}"),
        (["requiredIf": [:]], "X: requiredIf must name one variable and its value: {VAR: value}"),
        (["requiredIf": ["FLAG": 1.5]], "X: requiredIf must name one variable and a string, integer or boolean value"),
        (["requiredIf": ["FLAG": ["a"]]], "X: requiredIf must name one variable and a string, integer or boolean value"),
        (["requiredIf": ["MISSING": true]], "X: requiredIf must name another declared variable, not MISSING"),
        (["requiredIf": ["X": "a"]], "X: requiredIf must name another declared variable, not X"),
        (["requiredIf": ["TOKEN": "a"]], "X: requiredIf names TOKEN, which is not a plain string, int, bool or enum variable"),
        (["requiredIf": ["TIMEOUT": "1m"]], "X: requiredIf names TIMEOUT, which is not a plain string, int, bool or enum variable"),
        // Bool apart from int.
        (["requiredIf": ["FLAG": 1]], "X: requiredIf: FLAG is 1 is not a value FLAG can have"),
        (["requiredIf": ["COUNT": true]], "X: requiredIf: COUNT is true is not a value COUNT can have"),
        (["requiredIf": ["COUNT": "3"]], #"X: requiredIf: COUNT is "3" is not a value COUNT can have"#),
        (["requiredIf": ["COUNT": 99]], #"X: requiredIf: COUNT is 99 is not a value COUNT can have: is above max 10 (got "99")"#),
        (["requiredIf": ["MODE": "debug"]], #"X: requiredIf: MODE is "debug" is not a value MODE can have: is not one of a, b (got "debug")"#),
        (["requiredIf": ["FLAG": true], "required": true], "X: an input with requiredIf cannot be required"),
        (["requiredIf": ["FLAG": true], "default": "x"], "X: an input with requiredIf cannot have a default"),
        (["requiredIf": ["FLAG": true], "deprecated": ["message": "Use Y instead"]],
         "X: an input with requiredIf cannot be deprecated: the platform could not stop setting it"),
    ] as [(JSONValue, String)])
    func rejectsABadCondition(fields: JSONValue, problem: String) {
        guard case .object(let extra) = fields else { return }
        var x: [(String, JSONValue)] = [("type", "string"), ("description", "The conditional input")]
        x += extra
        let contract: JSONValue = ["vars": [
            "X": .object(x),
            "FLAG": ["type": "bool", "description": "A plain flag"],
            "COUNT": ["type": "int", "description": "A bounded count", "max": 10],
            "MODE": ["type": "enum", "description": "A mode to run in", "values": ["a", "b"]],
            "TOKEN": ["type": "string", "description": "A secret token", "secret": true],
            "TIMEOUT": ["type": "duration", "description": "A request timeout"],
        ]]
        #expect {
            try ContractDocument(contract: contract)
        } throws: { error in
            let problems = (error as! DeclarationError).problems
            if !problems.contains(problem) { Issue.record("problems \(problems) do not contain \(problem)") }
            return problems.contains(problem)
        }
    }

    @Test func aFileInputWithRequiredIfCannotBeRequired() {
        let contract: JSONValue = [
            "vars": ["FLAG": ["type": "bool", "description": "A plain flag"]],
            "files": ["allowlist": [
                "type": "text", "description": "Client names allowed", "path": "/etc/relay/allowlist/allow.txt",
                "required": true, "requiredIf": ["FLAG": true],
            ]],
        ]
        #expect {
            try ContractDocument(contract: contract)
        } throws: { error in
            (error as! DeclarationError).problems.contains("allowlist: an input with requiredIf cannot be required")
        }
    }
}

@Suite struct RolesTests {
    static let contract: JSONValue = [
        "apiVersion": "docuconf.dev/v1alpha1", "kind": "ConfigContract", "metadata": ["name": "shop"],
        "roles": ["web", "worker"],
        "includes": ["go-runtime@1"],
        "vars": [
            "DOCUCONF_ROLE": ["type": "enum", "description": "The role this workload runs", "required": true, "values": ["web", "worker"]],
            "DATABASE_URL": ["type": "string", "description": "Database connection string", "required": true],
            "ALLOWED_ORIGINS": [
                "type": "list", "description": "Origins the web server accepts", "items": "string", "required": true, "roles": ["web"],
            ],
            "QUEUES": [
                "type": "list", "description": "Queues the worker takes jobs from", "items": "string", "required": true,
                "roles": ["worker"],
            ],
            "CACHE_URL": [
                "type": "string", "description": "Cache the web server reads", "roles": ["web"], "requiredIf": ["DATABASE_URL": "cached"],
            ],
        ],
        "files": [
            "robots": [
                "type": "text", "description": "The robots.txt the web server serves", "required": true, "roles": ["web"],
                "path": "/etc/shop/robots/robots.txt",
            ],
        ],
    ]

    static func codes(_ env: [String: String]) async throws -> Set<String> {
        let doc = try ContractDocument(contract: Self.contract)
        let found = try await RequiredIfTests.violations(doc, env)
        return Set(found.map { "\($0.input)/\($0.code.rawValue)" })
    }

    @Test func readsRolesAndIncludes() throws {
        let doc = try ContractDocument(contract: Self.contract)
        #expect(doc.roles == ["web", "worker"])
        #expect(doc.inputRoles == ["ALLOWED_ORIGINS": ["web"], "QUEUES": ["worker"], "CACHE_URL": ["web"], "robots": ["web"]])
        #expect(doc.includes == ["go-runtime@1"])
    }

    /// An input that only other roles use is optional: a worker needs neither the web inputs nor the web file.
    @Test func narrowsToTheRole() async throws {
        #expect(try await Self.codes(["DOCUCONF_ROLE": "worker", "DATABASE_URL": "db"]) == ["QUEUES/missing_required"])
        #expect(try await Self.codes(["DOCUCONF_ROLE": "worker", "DATABASE_URL": "db", "QUEUES": "default"]).isEmpty)
        #expect(try await Self.codes(["DOCUCONF_ROLE": "web", "DATABASE_URL": "db"])
            == ["ALLOWED_ORIGINS/missing_required", "robots/file_missing"])
    }

    /// Without a valid role every role-specific input is optional, so the role is the one problem reported.
    @Test func withoutARoleOnlyTheRoleIsReported() async throws {
        #expect(try await Self.codes(["DATABASE_URL": "db"]) == ["DOCUCONF_ROLE/missing_required"])
        #expect(try await Self.codes(["DOCUCONF_ROLE": "cron", "DATABASE_URL": "db"]) == ["DOCUCONF_ROLE/not_in_enum"])
    }

    /// A condition makes an input required only in the roles that use it.
    @Test func conditionsHoldInRoleOnly() async throws {
        #expect(try await Self.codes(["DOCUCONF_ROLE": "worker", "DATABASE_URL": "cached", "QUEUES": "default"]).isEmpty)
        #expect(try await Self.codes([
            "DOCUCONF_ROLE": "web", "DATABASE_URL": "cached", "ALLOWED_ORIGINS": "https://shop.example",
        ]) == ["CACHE_URL/missing_required", "robots/file_missing"])
    }

    /// The reader's refusals (SPEC §4.9).
    @Test(arguments: [
        (["roles": []] as JSONValue, "roles must be a list of at least one role name"),
        (["roles": "web"], "roles must be a list of at least one role name"),
        (["roles": ["Web"]], #"role "Web" must be a DNS label"#),
        (["roles": ["web", "web"]], "role web is listed twice"),
        (["roles": ["web"], "inputRoles": ["cron"]], "X: role cron is not one of the contract's roles, web"),
        (["inputRoles": ["web"]], "X: has roles, but the contract declares none"),
        (["inputRoles": []], "X: roles must be a list of at least one role name"),
        (["roles": ["web"], "roleVar": false], "DOCUCONF_ROLE: a contract with roles declares it as a required enum whose values are the roles, web, used by every role"),
        (["roles": ["web", "worker"]], "DOCUCONF_ROLE: a contract with roles declares it as a required enum whose values are the roles, web, worker, used by every role"),
        (["includes": ["otel"]], #"includes: "otel" is not a fragment name, name@major"#),
        (["includes": ["otel@1", "otel@1"]], "includes: otel@1 is listed twice"),
        (["includes": "otel@1"], "includes must be a list of fragment names, such as otel@1"),
    ] as [(JSONValue, String)])
    func rejectsBadRoles(fields: JSONValue, problem: String) {
        var x: [(String, JSONValue)] = [("type", "string"), ("description", "An input of some roles")]
        if let r = fields["inputRoles"] { x.append(("roles", r)) }
        var vars: [(String, JSONValue)] = [("X", .object(x))]
        if fields["roleVar"] != false {
            vars.append(("DOCUCONF_ROLE", ["type": "enum", "description": "The role this workload runs", "required": true, "values": ["web"]]))
        }
        var contract: [(String, JSONValue)] = [("vars", .object(vars))]
        if let r = fields["roles"] { contract.append(("roles", r)) }
        if let i = fields["includes"] { contract.append(("includes", i)) }
        #expect {
            try ContractDocument(contract: .object(contract))
        } throws: { error in
            let problems = (error as! DeclarationError).problems
            if !problems.contains(problem) { Issue.record("problems \(problems) do not contain \(problem)") }
            return problems.contains(problem)
        }
    }
}
