import Docuconf
import Foundation
import Testing

/// The shared conformance suite (SPEC §12), run through contract-first mode with the server SDK's file support.
///
/// `cases.json` comes from `DOCUCONF_CONFORMANCE`, or else a `docuconf-go` checkout next to this repository. When
/// it is missing the suite is skipped, unless `DOCUCONF_REQUIRE_CONFORMANCE=1` (as in CI), which also fails the
/// suite when any case is skipped.
@Suite struct ConformanceTests {
    /// The capability tags this SDK supports: an allow-list, so a case with a tag the runner does not know is
    /// skipped, never run (SPEC §12). `files` needs the package's `TLS` trait, which builds the certificate and
    /// keystore checks; CI runs the suite with it, and requires 0 skipped.
    static var supportedTags: Set<String> {
        var tags: Set<String> = ["int64", "json-schema", "key-set", "deprecated", "strict-parsing", "profiles", "overlays"]
        #if TLS
        tags.insert("files")
        #endif
        return tags
    }

    static let env = ProcessInfo.processInfo.environment
    static let packageRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    static var casesURL: URL {
        if let p = env["DOCUCONF_CONFORMANCE"], !p.isEmpty { return URL(fileURLWithPath: p) }
        return packageRoot.deletingLastPathComponent().appendingPathComponent("docuconf-go/conformance/cases.json")
    }

    static var required: Bool { env["DOCUCONF_REQUIRE_CONFORMANCE"] == "1" }

    @Test func sharedSuite() async throws {
        let url = Self.casesURL
        guard let data = FileManager.default.contents(atPath: url.path) else {
            if Self.required {
                Issue.record("conformance cases not found at \(url.path); set DOCUCONF_CONFORMANCE")
            } else {
                print("conformance: skipped, \(url.path) not found (set DOCUCONF_CONFORMANCE)")
            }
            return
        }
        let file = try JSONDecoder().decode(JSONValue.self, from: data)
        #expect(file["version"] == 1, "unknown cases.json version")
        guard case .array(let cases)? = file["cases"] else {
            Issue.record("cases.json has no cases")
            return
        }
        var passed = 0
        var skipped: [String: Int] = [:]
        var failed: [String] = []
        for c in cases {
            let id = c["id"].flatMap { if case .string(let s) = $0 { s } else { nil } } ?? "?"
            let missing = Set(Self.strings(c["requires"])).subtracting(Self.supportedTags)
            if !missing.isEmpty {
                for tag in missing { skipped[tag, default: 0] += 1 }
                continue
            }
            if let why = await Self.run(c) {
                failed.append(id)
                Issue.record("conformance case \"\(id)\" failed: \(why)")
            } else {
                passed += 1
            }
        }
        let skippedText = skipped.sorted { $0.key < $1.key }.map { "\($0.value) \($0.key)" }.joined(separator: ", ")
        let skippedCount = skipped.values.reduce(0, +)
        if skippedCount > 0 && Self.required {
            Issue.record("\(skippedCount) conformance cases skipped (\(skippedText)); CI requires 0")
        }
        print("conformance: \(passed) passed, \(skippedCount) skipped\(skippedText.isEmpty ? "" : " (\(skippedText))"), \(failed.count) failed of \(cases.count)")
    }

    static func strings(_ v: JSONValue?) -> [String] {
        guard case .array(let a)? = v else { return [] }
        return a.compactMap { if case .string(let s) = $0 { s } else { nil } }
    }

    /// Collects warnings, to check that none holds a secret.
    final class Warnings: @unchecked Sendable {
        private let lock = NSLock()
        private var lines: [String] = []
        func add(_ s: String) { lock.withLock { lines.append(s) } }
        var all: [String] { lock.withLock { lines } }
    }

    /// Runs one case; returns why it failed, or `nil`.
    static func run(_ c: JSONValue) async -> String? {
        guard let contractJSON = c["contract"] else { return "no contract" }
        var environment: [String: String] = [:]
        if case .object(let members)? = c["env"] {
            for (k, v) in members {
                guard case .string(let s) = v else { return "env \(k) is not a string" }
                environment[k] = s
            }
        }

        // A fresh, empty directory as DOCUCONF_FILE_ROOT for every case, files or not, so no case reads the
        // machine's own files.
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("docuconf-conformance-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: root) }
        do {
            try fm.createDirectory(at: root, withIntermediateDirectories: true)
            if case .object(let files)? = c["files"] {
                for (path, content) in files {
                    let bytes: Data
                    if case .string(let text)? = content["text"] {
                        bytes = Data(text.utf8)
                    } else if case .string(let b64)? = content["base64"], let decoded = Data(base64Encoded: b64) {
                        bytes = decoded
                    } else {
                        return "file \(path) has neither text nor base64 content"
                    }
                    let url = root.appendingPathComponent(String(path.drop { $0 == "/" }))
                    try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try bytes.write(to: url)
                }
            }
        } catch {
            return "could not write the case's files: \(error)"
        }
        environment["DOCUCONF_FILE_ROOT"] = root.path

        let contract: ContractDocument
        do {
            contract = try ContractDocument(contract: contractJSON)
        } catch {
            return "contract rejected: \(error)"
        }
        let warnings = Warnings()
        let result: Result<ContractValues, ConfigurationError>
        do {
            result = .success(try await contract.load(environment: environment, support: DocuconfFileSupport(), warn: warnings.add))
        } catch {
            result = .failure(error)
        }

        // No error output or warning may contain the raw value of a secret variable.
        let secretValues = contract.vars.filter(\.secret).flatMap { spec in
            environment.filter { $0.key == spec.name || $0.key.hasPrefix(spec.name + "__") }.map(\.value)
        }.filter { !$0.isEmpty }
        for line in warnings.all {
            if secretValues.contains(where: line.contains) { return "a warning contains the value of a secret: \(line)" }
        }

        if let expect = c["expect"] {
            switch result {
            case .failure(let e):
                return "expected values, got \(e)"
            case .success(let values):
                guard case .object(let expected) = expect else { return "expect is not an object" }
                let got = values.json
                var diffs: [String] = []
                for (name, want) in expected {
                    let value = got[name] ?? .null
                    if !sameJSON(value, want) { diffs.append("\(name): got \(value.jsonText), want \(want.jsonText)") }
                }
                return diffs.isEmpty ? nil : diffs.joined(separator: "; ")
            }
        }

        guard case .array(let errors)? = c["errors"] else { return "case has neither expect nor errors" }
        let want = Set(errors.compactMap { e -> String? in
            guard case .string(let v)? = e["var"], case .string(let code)? = e["code"] else { return nil }
            return "\(v)/\(code)"
        })
        switch result {
        case .success(let values):
            return "expected errors \(want.sorted()), loaded \(values.json.jsonText)"
        case .failure(let e):
            let got = Set(e.violations.map { "\($0.input)/\($0.code.rawValue)" })
            if got != want { return "errors \(got.sorted()), want \(want.sorted()): \(e)" }
            let output = e.description
            if secretValues.contains(where: output.contains) { return "error output contains the value of a secret" }
            return nil
        }
    }

    /// JSON equality with numbers compared numerically (`3` equals `3.0`) and objects compared as maps.
    static func sameJSON(_ a: JSONValue, _ b: JSONValue) -> Bool {
        switch (a, b) {
        case (.int(let x), .int(let y)): return x == y
        case (.int, .double), (.double, .int), (.double, .double): return number(a) == number(b)
        case (.array(let x), .array(let y)): return x.count == y.count && zip(x, y).allSatisfy(sameJSON)
        case (.object(let x), .object(let y)):
            let dx = Dictionary(x, uniquingKeysWith: { a, _ in a })
            let dy = Dictionary(y, uniquingKeysWith: { a, _ in a })
            return dx.count == dy.count && dx.allSatisfy { k, v in dy[k].map { sameJSON(v, $0) } ?? false }
        default: return a == b
        }
    }

    static func number(_ v: JSONValue) -> Double? {
        switch v {
        case .int(let i): Double(i)
        case .double(let d): d
        default: nil
        }
    }
}
