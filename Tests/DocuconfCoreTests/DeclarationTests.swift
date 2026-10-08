import DocuconfCore
import Foundation
import Testing

@Suite struct DeclarationTests {
    func problems<C: DocuconfConfig>(_ type: C.Type) -> [String] {
        do {
            _ = try Declaration(type)
            return []
        } catch let e as DeclarationError {
            return e.problems
        } catch {
            return ["unexpected \(error)"]
        }
    }

    @Test func fixtureIsValid() throws {
        let d = try Declaration(GatewayConfig.self)
        #expect(d.vars.count == 16)
        #expect(d.files.count == 7)
        #expect(d.warnings.isEmpty)
    }

    @Test func requiredOptionalAndDefaults() throws {
        let d = try Declaration(GatewayConfig.self)
        let v = Dictionary(uniqueKeysWithValues: d.vars.map { ($0.name, $0) })
        #expect(v["DATABASE_URL"]?.required == true)
        #expect(v["OTEL_ENDPOINT"]?.required == false)
        #expect(v["OTEL_ENDPOINT"]?.defaultValue == nil)
        #expect(v["HTTP_PORT"]?.required == false)
        #expect(v["HTTP_PORT"]?.defaultValue == 8080)
        let f = Dictionary(uniqueKeysWithValues: d.files.map { ($0.name, $0) })
        #expect(f["routes"]?.required == true)
        #expect(f["trusted-cas"]?.required == false)
        #expect(f["serving-tls"]?.secret == true)
        #expect(f["partner"]?.secret == true)
        #expect(f["settings"]?.format == .yaml)
        #expect(f["partner"]?.keystoreFormat == .pkcs12)
    }

    @Test func shortDescription() {
        struct C: DocuconfConfig { @Env("port", "Port") var port = 8080 }
        #expect(problems(C.self) == ["PORT: description must be at least 5 characters"])
    }

    @Test func invalidName() {
        struct C: DocuconfConfig { @Env("9lives", "Number of lives") var lives = 9 }
        #expect(problems(C.self).first?.contains("does not map to a valid variable name") == true)
    }

    @Test func duplicateName() {
        struct C: DocuconfConfig {
            @Env("http.port", "HTTP listen port") var a = 1
            @Env("httpPort", "HTTP listen port again") var b = 2
        }
        #expect(problems(C.self).first?.contains("declared twice") == true)
    }

    @Test func defaultMustSatisfyConstraints() {
        struct C: DocuconfConfig {
            @Env("port", "HTTP listen port", .range(1...65535)) var port = 70000
            @Env("name", "Service name", .pattern("^[a-z]+$")) var name = "Gateway"
            @Env("brokers", "Kafka brokers", .minItems(2)) var brokers = ["kafka-0"]
            @Env("timeout", "Request timeout", .max(.seconds(5))) var timeout: Duration = .seconds(30)
        }
        let p = problems(C.self)
        #expect(p.count == 4)
        #expect(p.allSatisfy { $0.contains("violates its own constraints") })
    }

    @Test func secretCannotHaveDefault() {
        struct C: DocuconfConfig { @Env("api.key", "Partner API key", .secret) var apiKey = "hunter2" }
        #expect(problems(C.self).first?.contains("a secret cannot have a default") == true)
    }

    @Test func secretCannotHaveExamples() {
        struct C: DocuconfConfig { @Env("api.key", "Partner API key", .secret, .examples("abc")) var apiKey: String }
        #expect(problems(C.self) == ["API_KEY: a secret cannot have examples"])
    }

    @Test(arguments: ["(?=x)", "(?!x)", "(?<=x)a", "(?<!x)a", "(a)\\1", "a*+", "(?>a)", "\\Z"])
    func nonRE2PatternsAreRejected(pattern: String) {
        #expect(RE2.problem(in: pattern) != nil)
    }

    @Test(arguments: ["^[a-z]+$", "(?P<name>a+)", "(?i)abc", "[(?=]", "a{2,3}", "\\d+\\.\\d+", "^\\$[0-9]+$"])
    func re2PatternsAreAccepted(pattern: String) {
        #expect(RE2.problem(in: pattern) == nil)
    }

    @Test func badPatternInDeclaration() {
        struct C: DocuconfConfig { @Env("name", "Service name", .pattern("^(?!admin)")) var name = "x" }
        #expect(problems(C.self).first?.contains("lookahead") == true)
    }

    @Test func pathEnvMustNotBeAVar() {
        struct C: DocuconfConfig {
            @Env("routes.file", "Where the routes are") var routesFile = "/x"
            @FileInput("routes", "Routing table", path: "/etc/gw/routes/routes.json", .pathEnv("ROUTES_FILE"))
            var routes: ConfigFile<[String: String]>
        }
        #expect(problems(C.self) == ["routes: pathEnv ROUTES_FILE must not also be declared as a variable"])
    }

    @Test func passwordVarMustBeADeclaredSecret() {
        struct C: DocuconfConfig {
            @Env("ks.password", "Keystore password") var password = "changeit"
            @FileInput("ks", "Client keystore", path: "/etc/gw/ks/client.p12", .passwordVar("KS_PASSWORD")) var ks: Keystore
            @FileInput("other", "Other keystore", path: "/etc/gw/other/client.p12", .passwordVar("MISSING")) var other: Keystore
        }
        #expect(problems(C.self) == [
            "ks: passwordVar KS_PASSWORD must be a secret variable",
            "other: passwordVar MISSING is not a declared variable",
        ])
    }

    @Test func mountRules() {
        struct C: DocuconfConfig {
            @FileInput("bundle", "Private CA bundle", path: "/etc/ssl/certs/private.pem") var bundle: CABundle
            @FileInput("a", "First file here", path: "/etc/gw/conf/a.txt") var a: TextFile
            @FileInput("b", "Second file here", path: "/etc/gw/conf/b.txt") var b: TextFile
            @FileInput("c", "Not normalised", path: "/etc/gw/../c.txt") var c: TextFile
            @FileInput("Bad_Name", "Bad input name", path: "/etc/gw/bad/x.txt") var d: TextFile
        }
        let p = problems(C.self)
        #expect(p.contains { $0.hasPrefix("bundle: would be mounted at /etc/ssl/certs") })
        #expect(p.contains("b: shares mount directory /etc/gw/conf with a"))
        #expect(p.contains { $0.hasPrefix("c: path /etc/gw/../c.txt must be absolute and normalised") })
        #expect(p.contains { $0.hasPrefix("Bad_Name: file input names must be DNS labels") })
    }

    @Test func configFormatIsInferredOrRequired() {
        struct C: DocuconfConfig {
            @FileInput("conf", "Some config file", path: "/etc/gw/conf/app.conf") var conf: ConfigFile<[String: Int]>
        }
        #expect(problems(C.self) == ["conf: cannot infer the config format from /etc/gw/conf/app.conf; add .format(...)"])
        struct D: DocuconfConfig {
            @FileInput("conf", "Some config file", path: "/etc/gw/conf/app.conf", .format(.yaml)) var conf: ConfigFile<[String: Int]>
        }
        #expect(problems(D.self).isEmpty)
    }

    @Test func featureFlagWarning() throws {
        struct C: DocuconfConfig { @Env("enable.newCheckout", "New checkout flow") var on = false }
        let d = try Declaration(C.self)
        #expect(d.vars[0].name == "ENABLE_NEW_CHECKOUT")
        #expect(d.warnings.count == 1)
        #expect(d.warnings[0].contains("feature flag"))
    }

    @Test func itemBoundsFromTheItemType() throws {
        struct C: DocuconfConfig {
            @Env("a", "Plain Int items") var a: [Int]?
            @Env("b", "Signed 32-bit items") var b: [Int32]?
            @Env("c", "Unsigned 16-bit items") var c: [UInt16]?
            @Env("d", "Unsigned 64-bit items") var d: [UInt64]?
            @Env("e", "Narrowed by a rule", .itemRange(1...10)) var e: [UInt8]?
            @Env("f", "String items") var f: [String]?
        }
        let v = Dictionary(uniqueKeysWithValues: try Declaration(C.self).vars.map { ($0.name, $0) })
        #expect(v["A"]?.itemMin == nil && v["A"]?.itemMax == nil)
        #expect(v["B"]?.itemMin == Int(Int32.min) && v["B"]?.itemMax == Int(Int32.max))
        #expect(v["C"]?.itemMin == 0 && v["C"]?.itemMax == 65535)
        #expect(v["D"]?.itemMin == 0 && v["D"]?.itemMax == nil)
        #expect(v["E"]?.itemMin == 1 && v["E"]?.itemMax == 10)
        #expect(v["F"]?.itemMin == nil && v["F"]?.itemMax == nil)
        let fields = Contract.fields(v["C"]!)
        #expect(fields.first { $0.0 == "itemMin" }?.1 == 0)
        #expect(fields.first { $0.0 == "itemMax" }?.1 == 65535)
    }

    @Test func itemBoundsOutsideTheItemType() {
        struct C: DocuconfConfig {
            @Env("a", "Too wide for UInt8", .itemRange(-1...300)) var a: [UInt8]?
            @Env("b", "Inverted bounds", .itemMin(5), .itemMax(1)) var b: [Int]?
            @Env("c", "Default breaks the bounds", .itemMax(3)) var c = [1, 4]
        }
        let p = problems(C.self)
        #expect(p.contains("A: itemMin -1 is outside the range of UInt8"))
        #expect(p.contains("A: itemMax 300 is outside the range of UInt8"))
        #expect(p.contains("B: itemMin 5 is above itemMax 1"))
        #expect(p.contains { $0.hasPrefix("C: default [1,4] violates its own constraints: item 1 is above itemMax 3") })
    }

    struct RunLimits: JSONConfigValue { var max: Int }

    @Test func lengthLimitsOnURLsJSONAndListItems() throws {
        struct C: DocuconfConfig {
            @Env("callback.url", "Where to report the run, PIC X(40)", .schemes("https"), .maxLength(40))
            var callback = URL(string: "https://ledger.example.com/runs/callback")!
            @Env("limits", "Run limits as JSON, PIC X(16)", .maxLength(16)) var limits = RunLimits(max: 12_345_678)
            @Env("branches", "Branch codes of PIC X(4)", .itemLength(2...4)) var branches = ["ZÜ01", "BE", "GE02"]
            @Env("codes", "Codes", .itemMinLength(1), .itemMaxLength(2)) var codes = ["日本", "😀"]
        }
        let v = Dictionary(uniqueKeysWithValues: try Declaration(C.self).vars.map { ($0.name, $0) })
        #expect(v["CALLBACK_URL"]?.maxLength == 40)
        #expect(v["LIMITS"]?.maxLength == 16)
        #expect(v["BRANCHES"]?.itemMinLength == 2 && v["BRANCHES"]?.itemMaxLength == 4)
        #expect(v["CODES"]?.itemMinLength == 1 && v["CODES"]?.itemMaxLength == 2)
        let branches = Contract.fields(v["BRANCHES"]!)
        #expect(branches.first { $0.0 == "itemMinLength" }?.1 == 2)
        #expect(branches.first { $0.0 == "itemMaxLength" }?.1 == 4)
        #expect(Contract.fields(v["LIMITS"]!).first { $0.0 == "maxLength" }?.1 == 16)
        #expect(Contract.fields(v["CALLBACK_URL"]!).first { $0.0 == "maxLength" }?.1 == 40)
    }

    @Test func lengthLimitDeclarationErrors() {
        struct C: DocuconfConfig {
            @Env("codes", "Inverted item lengths", .itemMinLength(5), .itemMaxLength(4)) var codes: [String]?
            @Env("site", "Default URL too long", .maxLength(10)) var site = URL(string: "https://example.com")!
            @Env("branches", "Default item too long", .itemMaxLength(4)) var branches = ["BE", "ZÜRICH"]
            @Env("regions", "Default item too short", .itemMinLength(2)) var regions = ["B"]
            @Env("limits", "Default JSON too long", .maxLength(16)) var limits = RunLimits(max: 123_456_789)
        }
        let p = problems(C.self)
        #expect(p.contains("CODES: itemMinLength 5 is above itemMaxLength 4"))
        #expect(p.contains { $0.hasPrefix("SITE: default \"https://example.com\" violates its own constraints: is 19 characters, longer than 10") })
        #expect(p.contains { $0.hasPrefix("BRANCHES: default [\"BE\",\"ZÜRICH\"] violates its own constraints: item 1 is 6 characters, longer than 4") })
        #expect(p.contains { $0.hasPrefix("REGIONS: default [\"B\"] violates its own constraints: item 0 is 1 characters, shorter than 2") })
        #expect(p.contains("LIMITS: default {\"max\":123456789} violates its own constraints: is 17 characters of JSON, longer than 16"))

        // The rules only exist on the right types; a spec built by hand (or a contract) is checked too.
        var ints = VarSpec(name: "PORTS", key: "ports", type: .list, description: "Ports to open")
        ints.items = .int
        ints.itemMaxLength = 5
        var flag = VarSpec(name: "FLAG", key: "flag", type: .bool, description: "A boolean flag")
        flag.maxLength = 5
        let q = Declaration.validate(vars: [ints, flag], files: []).problems
        #expect(q.contains("PORTS: itemMinLength and itemMaxLength apply only to lists of strings"))
        #expect(q.contains("FLAG: maxLength applies only to string, url and json variables"))
    }

    @Test func lengthsCountUnicodeScalars() {
        var url = VarSpec(name: "U", key: "u", type: .url, description: "A URL")
        url.maxLength = 24
        #expect(url.check(.url("https://例え.jp/日本語の道/一二三四")).isEmpty)
        #expect(url.check(.url("https://例え.jp/日本語の道/一二三四五")).map(\.code) == [.outOfRange])
        var json = VarSpec(name: "J", key: "j", type: .json, description: "JSON")
        json.maxLength = 16
        #expect(json.check(.json(#"{"n":"日本語の道路xy"}"#)).isEmpty)
        // An emoji is one scalar but two UTF-16 units.
        #expect(json.check(.json(#"{"n":"😀😀😀😀😀😀😀😀"}"#)).isEmpty)
        #expect(json.check(.json(#"{ "max": 123456 }"#)).map(\.code) == [.outOfRange])
        var list = VarSpec(name: "L", key: "l", type: .list, description: "List")
        list.items = .string
        list.itemMaxLength = 4
        #expect(list.check(.stringList(["ZÜ01", "日本", "😀😀😀😀"])).isEmpty)
        #expect(list.check(.stringList(["BE", "ZÜRICH"])).map(\.code) == [.outOfRange])
        // A secret reports its length, never its value.
        var secret = VarSpec(name: "S", key: "s", type: .url, description: "Secret URL")
        secret.secret = true
        secret.maxLength = 30
        let m = secret.check(.url("postgres://app:s3cr3t@db:5432/app")).map(\.message)
        #expect(m == ["is 33 characters, longer than 30"])
    }
}
