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
        #expect(d.vars.count == 14)
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
}
