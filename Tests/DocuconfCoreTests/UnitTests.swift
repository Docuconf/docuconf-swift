import DocuconfCore
import Foundation
import Testing

@Suite struct GoDurationTests {
    @Test(arguments: [
        (Duration.seconds(90), "1m30s"), (.seconds(5400), "1h30m"), (.zero, "0s"), (.milliseconds(1500), "1s500ms"),
        (.seconds(720 * 3600), "720h"), (.nanoseconds(1), "1ns"), (.microseconds(2), "2us"), (.seconds(3600), "1h"),
    ])
    func format(d: Duration, s: String) {
        #expect(GoDuration.format(d) == s)
        #expect(GoDuration.parse(s) == d)
    }

    @Test func parseNonCanonical() {
        #expect(GoDuration.parse("90m") == .seconds(5400))
        #expect(GoDuration.parse("1m5ms") == .milliseconds(60005))
        #expect(GoDuration.parse("1.5h") == nil)
        #expect(GoDuration.parse("") == nil)
        #expect(GoDuration.parse("10") == nil)
        #expect(GoDuration.parse("-1s") == nil)
    }
}

@Suite struct EnvNameTests {
    @Test(arguments: [
        ("http.port", "HTTP_PORT"), ("http.serverTimeout", "HTTP_SERVER_TIMEOUT"), ("databaseURL", "DATABASE_URL"),
        ("http.client.user-agent", "HTTP_CLIENT_USER_AGENT"), ("port", "PORT"), ("ROUTES_FILE", "ROUTES_FILE"),
        ("partner.keystorePassword", "PARTNER_KEYSTORE_PASSWORD"), ("retry.backoffMs", "RETRY_BACKOFF_MS"),
    ])
    func mapping(key: String, name: String) {
        #expect(EnvName.forKey(key) == name)
    }
}

@Suite struct RE2Tests {
    @Test func partialMatch() {
        #expect(RE2.matches("[0-9]", "abc1def"))
        #expect(!RE2.matches("^[0-9]+$", "12a"))
    }

    @Test func dollarMatchesOnlyAtEnd() {
        // RE2 (and CUE, Go) `$` without (?m) does not match before a trailing newline.
        #expect(!RE2.matches("^abc$", "abc\n"))
        #expect(RE2.matches("^abc\\n?$", "abc\n"))
        #expect(RE2.matches("(?m)^abc$", "abc\nxyz"))
    }

    @Test func classesAreASCIIOnly() {
        // RE2's \d, \w, \s and \b are ASCII-only (SPEC §4.3), unlike Swift Regex's defaults.
        #expect(!RE2.matches("^\\d$", "\u{0663}"))  // ARABIC-INDIC DIGIT THREE
        #expect(RE2.matches("^\\d$", "3"))
        #expect(!RE2.matches("^\\w+$", "caf\u{E9}"))
        #expect(!RE2.matches("\\s", "\u{00A0}"))
        #expect(RE2.matches("\\bcat\\b", "a cat sat"))
        #expect(!RE2.matches("^[[:alpha:]]+$", "\u{E9}t\u{E9}"))
    }

    @Test func pythonNamedGroups() {
        #expect(RE2.matches("(?P<word>[a-z]+)-1", "abc-1"))
    }

    @Test func dotMatchesScalarsNotGraphemes() {
        // "e" + combining acute accent is one grapheme but two scalars, as RE2 counts.
        #expect(RE2.matches("^e.$", "e\u{301}"))
    }
}

@Suite struct ParseTests {
    func spec(_ t: VarType, secret: Bool = false) -> VarSpec {
        var s = VarSpec(name: "X", key: "x", type: t, description: "A variable")
        s.secret = secret
        return s
    }

    func code(_ r: Result<ParsedValue, Violation>?) -> ViolationCode? {
        guard case .failure(let v)? = r else { return nil }
        return v.code
    }

    @Test func emptyIsUnsetExceptForStrings() throws {
        #expect(spec(.int).parse(wire: "") == nil)
        #expect(spec(.bool).parse(wire: "") == nil)
        #expect(try spec(.string).parse(wire: "")?.get() == .string(""))
    }

    @Test func numbers() throws {
        #expect(try spec(.int).parse(wire: "8080")?.get() == .int(8080))
        #expect(spec(.int).parse(wire: "8080.0").map { (try? $0.get()) == nil } == true)
        #expect(spec(.int).parse(wire: "99999999999999999999").map { (try? $0.get()) == nil } == true)
        #expect(code(spec(.int).parse(wire: "99999999999999999999")) == .outOfRange)
        #expect(code(spec(.int).parse(wire: "ten")) == .invalidType)
        #expect(spec(.float).parse(wire: "0x1p3").map { (try? $0.get()) == nil } == true)
        #expect(spec(.float).parse(wire: "0,5").map { (try? $0.get()) == nil } == true)
        #expect(try spec(.float).parse(wire: "1e3")?.get() == .double(1000))
        #expect(spec(.float).parse(wire: "NaN").map { (try? $0.get()) == nil } == true)
        #expect(spec(.float).parse(wire: "inf").map { (try? $0.get()) == nil } == true)
        #expect(try spec(.float).parse(wire: "0.5")?.get() == .double(0.5))
    }

    @Test func bools() throws {
        #expect(try spec(.bool).parse(wire: "TRUE")?.get() == .bool(true))
        #expect(try spec(.bool).parse(wire: "False")?.get() == .bool(false))
    }

    @Test func valuesAreNeverTrimmed() throws {
        #expect(try spec(.string).parse(wire: " a \n")?.get() == .string(" a \n"))
    }

    @Test func secretValuesStayOutOfMessages() {
        var s = spec(.string, secret: true)
        s.pattern = "^[a-z]+$"
        s.minLength = 20
        let violations = s.check(.string("Hunter2"))
        #expect(violations.count == 2)
        #expect(violations.allSatisfy { !$0.description.contains("Hunter2") })
        var u = spec(.url, secret: true)
        u.schemes = ["postgres"]
        let v = u.check(.url("mysql://user:pw@db/x"))
        #expect(v.map(\.code) == [.invalidScheme])
        #expect(!v[0].description.contains("pw@db") && !v[0].description.contains("mysql"))
    }

    @Test func urlShape() {
        #expect(VarSpec.urlScheme("postgres://db:5432/x") == "postgres")
        #expect(VarSpec.urlScheme("db:5432") == nil)
        #expect(VarSpec.urlScheme("1http://x") == nil)
        #expect(VarSpec.urlScheme("http://") == nil)
    }
}

@Suite struct SchemaTests {
    @Test func derivedFromDecodable() throws {
        let schema = try JSONSchema.generate(Routes.self)
        #expect(schema["type"] == "object")
        #expect(schema["required"] == ["items"])
        let route = schema["properties"]?["items"]?["items"]
        #expect(route?["required"] == ["match", "upstream"])
        #expect(route?["properties"]?["upstream"] == ["type": "string", "format": "uri"])
        #expect(route?["properties"]?["methods"] == ["type": "array", "items": ["type": "string"]])
        #expect(route?["properties"]?["timeoutSeconds"] == ["type": "number"])
    }

    @Test func mapsEnumsAndNesting() throws {
        let schema = try JSONSchema.generate(Settings.self)
        #expect(schema["properties"]?["currency"] == ["type": "string", "enum": ["EUR", "USD"]])
        #expect(schema["properties"]?["limits"] == ["type": "object", "additionalProperties": ["type": "integer"]])
        #expect(schema["properties"]?["flags"]?["required"] == ["strict"])
    }

    @Test func schemaProviding() throws {
        struct Port: Decodable, JSONSchemaProviding {
            let value: Int
            init(from decoder: any Decoder) throws {
                value = try decoder.singleValueContainer().decode(Int.self)
                guard (1...65535).contains(value) else { throw DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "port")) }
            }
            static var jsonSchema: JSONValue { ["type": "integer", "minimum": 1, "maximum": 65535] }
        }
        struct Server: Decodable { var port: Port }
        let schema = try JSONSchema.generate(Server.self)
        #expect(schema["properties"]?["port"] == ["type": "integer", "minimum": 1, "maximum": 65535])
    }

    @Test func jsonVariableRoundTrip() throws {
        let v = try RateLimit(parsed: .json(#"{"requestsPerSecond":5,"burst":10}"#))
        #expect(v == RateLimit(requestsPerSecond: 5, burst: 10, exempt: nil))
        #expect(throws: ValueConversionError.self) { try RateLimit(parsed: .json(#"{"burst":10}"#)) }
        #expect(throws: ValueConversionError.self) { try RateLimit(parsed: .json("{nope")) }
    }
}
