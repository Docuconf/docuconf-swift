import Configuration
import Docuconf
import Foundation
import Testing

struct TimeoutConfig: DocuconfConfig {
    @Env("request.timeout", "Upstream request timeout", .range(.seconds(1) ... .seconds(300))) var timeout: Duration = .seconds(30)
}

struct TypoConfig: DocuconfConfig {
    @Env("database.url", "Primary Postgres connection string", .secret) var databaseURL: URL
    @Env("host", "Host name to bind") var host = "0.0.0.0"
    @Env("home.dir", "Unrelated variable") var homeDir: String?
}

struct RequiredFileConfig: DocuconfConfig {
    @FileInput("routes", "Routing table", path: "/etc/svc/routes/routes.json") var routes: ConfigFile<Routes>
}

struct ExitConfig: DocuconfConfig {
    @Env("http.port", "HTTP listen port", .range(1...65535)) var port = 8080
    @Env("database.url", "Primary Postgres connection string", .secret) var databaseURL: URL
}

struct BrokenDeclaration: DocuconfConfig {
    @Env("http.port", "Port") var port = 8080  // description too short
}

let exitTestLog = FileManager.default.temporaryDirectory.appendingPathComponent("docuconf-exit-test-termination-log").path

@Suite struct HintTests {
    @Test func missingRequiredSaysWhatTheVariableIsAndSpotsATypo() async throws {
        let warnings = WarningSink()
        do {
            _ = try await Docuconf.load(
                TypoConfig.self, environment: ["DATABSE_URL": "postgres://u:hunter2@db/app", "HOME": "/root"], warn: warnings.add)
            Issue.record("expected a violation")
        } catch let e as ConfigurationError {
            #expect(e.violations.map(\.description) == [
                "DATABASE_URL [missing_required]: is required but not set (Primary Postgres connection string); DATABSE_URL is set, is it a typo?"
            ])
        }
        #expect(warnings.all == ["DATABSE_URL is set but not declared; did you mean DATABASE_URL?"], "HOME is not taken for HOST")
        #expect(!warnings.all.joined().contains("hunter2"))
    }

    @Test func goStyleDurationsSayWhatToWrite() async throws {
        for (raw, hint) in [("30s", "write 30"), ("1m30s", "write 90"), ("1500ms", "write 1.5")] {
            do {
                _ = try await Docuconf.load(TimeoutConfig.self, environment: ["REQUEST_TIMEOUT": raw])
                Issue.record("\(raw) should be rejected")
            } catch let e as ConfigurationError {
                #expect(e.violations.map(\.code) == [.invalidType])
                #expect(e.violations[0].message.contains(hint), "\(e)")
                #expect(e.violations[0].message.contains("(got \"\(raw)\")"))
            }
        }
    }

    @Test func outOfRangeDurationsQuoteTheValueAsWritten() async throws {
        do {
            _ = try await Docuconf.load(TimeoutConfig.self, environment: ["REQUEST_TIMEOUT": "0.5"])
            Issue.record("expected a violation")
        } catch let e as ConfigurationError {
            #expect(e.violations.map(\.description) == [#"REQUEST_TIMEOUT [out_of_range]: is below min 1s (got "0.5" seconds)"#])
        }
    }

    @Test func aMissingFileSuggestsTheFileRootLocally() async throws {
        do {
            _ = try await Docuconf.load(RequiredFileConfig.self, environment: [:])
            Issue.record("expected a violation")
        } catch let e as ConfigurationError {
            #expect(e.violations[0].message.contains("set DOCUCONF_FILE_ROOT"))
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("docuconf-empty-\(UUID().uuidString)").path
        do {
            _ = try await Docuconf.load(RequiredFileConfig.self, environment: [:], fileRoot: root)
            Issue.record("expected a violation")
        } catch let e as ConfigurationError {
            #expect(!e.violations[0].message.contains("DOCUCONF_FILE_ROOT"))
            #expect(e.violations[0].message.hasPrefix(root))
        }
    }
}

@Suite struct TestingSupportTests {
    @Test func anExplicitEnvironmentIgnoresTheProcessEnvironment() async throws {
        #expect(ProcessInfo.processInfo.environment["PATH"] != nil)
        struct PathConfig: DocuconfConfig {
            @Env("path", "Search path for helpers") var path: String?
        }
        let before = ProcessInfo.processInfo.environment
        let c = try await Docuconf.load(PathConfig.self, environment: [:])
        #expect(c.path == nil)
        #expect(ProcessInfo.processInfo.environment == before, "the process environment is never changed")
    }

}

@Suite struct ExitTests {
    @Test func loadOrExitPrintsTheProblemsOnceAndExits1() async throws {
        try? FileManager.default.removeItem(atPath: exitTestLog)
        let result = await #expect(processExitsWith: .exitCode(1), observing: [\.standardErrorContent]) {
            let options = LoadOptions(environment: ["HTTP_PORT": "0", "DOCUCONF_TERMINATION_LOG": exitTestLog])
            _ = await Docuconf.loadOrExit(ExitConfig.self, options: options)
        }
        let stderr = String(decoding: result?.standardErrorContent ?? [], as: UTF8.self)
        #expect(stderr == """
            docuconf: 2 configuration problems:
              - HTTP_PORT [out_of_range]: is below min 1 (got "0")
              - DATABASE_URL [missing_required]: is required but not set (Primary Postgres connection string)

            """)
        let log = try String(contentsOfFile: exitTestLog, encoding: .utf8)
        #expect(log.hasPrefix("docuconf: 2 configuration problems:"))
        try? FileManager.default.removeItem(atPath: exitTestLog)
    }

    @Test func loadOrExitWithAReaderReportsDeclarationErrorsCleanly() async {
        let result = await #expect(processExitsWith: .exitCode(1), observing: [\.standardErrorContent]) {
            let reader = ConfigReader(provider: InMemoryProvider(values: [:]))
            _ = await Docuconf.loadOrExit(BrokenDeclaration.self, from: reader, options: LoadOptions(environment: ["DOCUCONF_TERMINATION_LOG": ""]))
        }
        let stderr = String(decoding: result?.standardErrorContent ?? [], as: UTF8.self)
        #expect(stderr == "docuconf: invalid declaration:\n  - HTTP_PORT: description must be at least 5 characters\n")
    }

    @Test func exportHelp() async {
        let result = await #expect(processExitsWith: .success, observing: [\.standardOutputContent]) {
            Docuconf.exportIfRequested(ExitConfig.self, name: "exit", arguments: ["app", "docuconf-export", "--help"])
        }
        let stdout = String(decoding: result?.standardOutputContent ?? [], as: UTF8.self)
        #expect(stdout.contains("usage: <app> docuconf-export"))
    }

    @Test func exportToAMissingDirectorySaysSo() async {
        let result = await #expect(processExitsWith: .exitCode(1), observing: [\.standardErrorContent]) {
            Docuconf.exportIfRequested(ExitConfig.self, name: "exit", arguments: ["app", "docuconf-export", "--out", "/nonexistent-dir/x.cue"])
        }
        let stderr = String(decoding: result?.standardErrorContent ?? [], as: UTF8.self)
        #expect(stderr == "docuconf-export: cannot write /nonexistent-dir/x.cue: no such directory /nonexistent-dir\n")
    }

    @Test func aMistypedExportCommandDoesNotBootTheApp() async {
        await #expect(processExitsWith: .exitCode(2)) {
            Docuconf.exportIfRequested(ExitConfig.self, name: "exit", arguments: ["app", "docuconf_export"])
        }
    }
}

final class WarningSink: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [String] = []
    var all: [String] { lock.withLock { items } }
    var add: @Sendable (String) -> Void { { [self] w in lock.withLock { items.append(w) } } }
}
