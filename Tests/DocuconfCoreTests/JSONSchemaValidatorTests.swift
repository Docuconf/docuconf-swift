import DocuconfCore
import Foundation
import Testing

@Suite struct JSONSchemaValidatorTests {
    static func json(_ text: String) -> JSONValue {
        try! JSONDecoder().decode(JSONValue.self, from: Data(text.utf8))
    }

    static let limits = json(#"""
        {"type":"object","properties":{"perMinute":{"type":"integer","minimum":1},"burst":{"type":"integer","minimum":0},
         "tier":{"enum":["free","pro"]},"name":{"type":"string","minLength":2,"maxLength":4,"pattern":"^[a-z日本]+$"},
         "tags":{"type":"array","items":{"type":"string"},"minItems":1,"maxItems":2,"uniqueItems":true},
         "ratio":{"type":"number","exclusiveMinimum":0,"exclusiveMaximum":1},"step":{"type":"integer","multipleOf":5},
         "mode":{"const":"fast"},"id":{"anyOf":[{"type":"integer"},{"type":"string","format":"uuid"}]},
         "flag":{"oneOf":[{"type":"boolean"},{"type":"null"}]},"big":{"type":"integer","maximum":9223372036854775806}},
         "required":["perMinute"],"additionalProperties":false,"maxProperties":20}
        """#)

    @Test(arguments: [
        #"{"perMinute":1}"#,
        #"{"perMinute":60,"burst":0,"tier":"pro","name":"日本","tags":["a","b"],"ratio":0.5,"step":10,"mode":"fast","id":"x","flag":null}"#,
        #"{"perMinute":2.0,"id":3,"flag":true,"big":9223372036854775806}"#,
    ])
    func accepts(_ doc: String) {
        #expect(JSONSchemaValidator.validate(Self.json(doc), against: Self.limits) == [])
    }

    @Test(arguments: [
        (#"{"perMinute":0}"#, "/perMinute: below minimum 1"),
        (#"{"perMinute":1,"perHour":5}"#, "/: property perHour is not allowed"),
        (#"{}"#, "/: missing required property perMinute"),
        (#"[]"#, "/: expected object, got array"),
        (#"{"perMinute":1.5}"#, "/perMinute: expected integer, got number"),
        (#"{"perMinute":1,"tier":"gold"}"#, #"/tier: must be one of "free", "pro""#),
        (#"{"perMinute":1,"name":"日"}"#, "/name: shorter than 2 characters"),
        (#"{"perMinute":1,"name":"abcde"}"#, "/name: longer than 4 characters"),
        (#"{"perMinute":1,"name":"AB"}"#, "/name: does not match pattern ^[a-z日本]+$"),
        (#"{"perMinute":1,"tags":[]}"#, "/tags: needs at least 1 items, has 0"),
        (#"{"perMinute":1,"tags":["a","a"]}"#, "/tags: items must be unique"),
        (#"{"perMinute":1,"tags":[1]}"#, "/tags/0: expected string, got integer"),
        (#"{"perMinute":1,"ratio":1}"#, "/ratio: must be below 1"),
        (#"{"perMinute":1,"step":7}"#, "/step: not a multiple of 5"),
        (#"{"perMinute":1,"mode":"slow"}"#, #"/mode: must equal "fast""#),
        (#"{"perMinute":1,"id":true}"#, "/id: matches none of the allowed shapes (anyOf)"),
        (#"{"perMinute":1,"flag":1}"#, "/flag: must match exactly one shape (oneOf), matches 0"),
        // Integers compare exactly beyond 2^53.
        (#"{"perMinute":1,"big":9223372036854775807}"#, "/big: above maximum 9223372036854775806"),
    ])
    func rejects(_ doc: String, _ want: String) {
        #expect(JSONSchemaValidator.validate(Self.json(doc), against: Self.limits) == [want])
    }

    @Test func booleanAndNotSchemas() {
        #expect(JSONSchemaValidator.validate(.int(1), against: .bool(true)) == [])
        #expect(JSONSchemaValidator.validate(.int(1), against: .bool(false)) == ["/: no value is allowed here"])
        #expect(JSONSchemaValidator.validate(.int(1), against: Self.json(#"{"not":{"type":"integer"}}"#))
            == ["/: matches a disallowed shape (not)"])
        #expect(JSONSchemaValidator.validate(.string("x"), against: Self.json(#"{"allOf":[{"type":"string"},{"minLength":2}]}"#))
            == ["/: shorter than 2 characters"])
        #expect(JSONSchemaValidator.validate(Self.json(#"{"a":"x"}"#), against: Self.json(#"{"additionalProperties":{"type":"integer"}}"#))
            == ["/a: expected integer, got string"])
    }

    @Test func unsupportedKeywordsAreReported() {
        #expect(JSONSchemaValidator.problems(in: Self.limits) == [])
        let bad = Self.json(#"""
            {"type":"object","$ref":"#/x","properties":{"a":{"patternProperties":{}},"b":{"type":"decimal"},
             "c":{"pattern":"(?=x)"}},"minItems":-1}
            """#)
        let problems = JSONSchemaValidator.problems(in: bad)
        #expect(problems.contains("/$ref: keyword $ref is not supported by the docuconf validator"))
        #expect(problems.contains("/properties/a/patternProperties: keyword patternProperties is not supported by the docuconf validator"))
        #expect(problems.contains(#"/properties/b/type: unknown type "decimal""#))
        #expect(problems.contains { $0.hasPrefix("/properties/c/pattern: ") })
        #expect(problems.contains("/minItems: must be a non-negative integer"))
        #expect(JSONSchemaValidator.problems(in: .int(3)) == ["/: a schema must be an object or a boolean"])
    }

    // MARK: - contract-first mode

    static let contract: JSONValue = [
        "apiVersion": "docuconf.dev/v1alpha1", "kind": "ConfigContract", "metadata": ["name": "svc"],
        "vars": [
            "LIMITS": ["type": "json", "description": "Rate limits", "schema": limits, "default": ["perMinute": 60]],
            "SECRET_DOC": ["type": "json", "description": "Secret document", "secret": true,
                           "schema": ["type": "object", "additionalProperties": false]],
        ],
    ]

    @Test func contractFirstChecksTheSchema() async throws {
        let doc = try ContractDocument(contract: Self.contract)
        #expect(try await doc.load(environment: [:])["LIMITS"] == .json(#"{"perMinute":60}"#))
        #expect(try await doc.load(environment: ["LIMITS": #"{"perMinute":5}"#])["LIMITS"] == .json(#"{"perMinute":5}"#))
        await #expect {
            try await doc.load(environment: ["LIMITS": #"{"perMinute":0,"x":1}"#, "SECRET_DOC": #"{"hunter2":"hunter2"}"#])
        } throws: { error in
            let e = error as! ConfigurationError
            return e.violations.map { "\($0.input)/\($0.code.rawValue)" }.sorted() == ["LIMITS/schema_mismatch", "SECRET_DOC/schema_mismatch"]
                && e.violations.contains { $0.message == "does not match its schema: /perMinute: below minimum 1 (and 1 more)" }
                && !e.description.contains("hunter2")
        }
    }

    @Test func contractFirstRejectsSchemasItCannotEnforce() {
        let bad: JSONValue = ["apiVersion": "docuconf.dev/v1alpha1", "kind": "ConfigContract",
               "vars": ["DOC": ["type": "json", "description": "A document", "schema": ["$ref": "#/defs/x"]]]]
        #expect {
            try ContractDocument(contract: bad)
        } throws: { error in
            (error as! DeclarationError).problems.contains("DOC: schema /$ref: keyword $ref is not supported by the docuconf validator")
        }
        let badDefault: JSONValue = ["apiVersion": "docuconf.dev/v1alpha1", "kind": "ConfigContract",
            "vars": ["DOC": ["type": "json", "description": "A document", "schema": ["type": "array"], "default": ["a": 1]]]]
        #expect {
            try ContractDocument(contract: badDefault)
        } throws: { error in
            (error as! DeclarationError).problems.contains("DOC: default does not match its schema: /: expected array, got object")
        }
    }
}
