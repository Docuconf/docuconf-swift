import DocuconfCore
import Foundation
import Testing

/// The shared conformance suite (SPEC §12), run through contract-first mode.
///
/// `cases.json` comes from `DOCUCONF_CONFORMANCE`, or else a `docuconf-go` checkout next to this repository. When
/// it is missing the suite is skipped, unless `DOCUCONF_REQUIRE_CONFORMANCE=1` (as in CI).
@Suite struct ConformanceTests {
    /// Capability tags this SDK lacks (see the README): none. With `DOCUCONF_REQUIRE_CONFORMANCE=1` (as in CI) a
    /// skipped case fails the suite, so a tag added here cannot go unnoticed.
    static let unsupportedTags: Set<String> = []

    static let env = ProcessInfo.processInfo.environment
    static let packageRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    static var casesURL: URL {
        if let p = env["DOCUCONF_CONFORMANCE"], !p.isEmpty { return URL(fileURLWithPath: p) }
        return packageRoot.deletingLastPathComponent().appendingPathComponent("docuconf-go/conformance/cases.json")
    }

    @Test func sharedSuite() throws {
        let url = Self.casesURL
        guard let data = FileManager.default.contents(atPath: url.path) else {
            if Self.env["DOCUCONF_REQUIRE_CONFORMANCE"] == "1" {
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
            let requires = Set(Self.strings(c["requires"]))
            let missing = requires.intersection(Self.unsupportedTags)
            if !missing.isEmpty {
                for tag in missing { skipped[tag, default: 0] += 1 }
                continue
            }
            if let why = Self.run(c) {
                failed.append(id)
                Issue.record("conformance case \"\(id)\" failed: \(why)")
            } else {
                passed += 1
            }
        }
        let skippedText = skipped.sorted { $0.key < $1.key }.map { "\($0.value) \($0.key)" }.joined(separator: ", ")
        let skippedCount = skipped.values.reduce(0, +)
        if skippedCount > 0 && Self.env["DOCUCONF_REQUIRE_CONFORMANCE"] == "1" {
            Issue.record("\(skippedCount) conformance cases skipped (\(skippedText)); CI requires 0")
        }
        print("conformance: \(passed) passed, \(skipped.values.reduce(0, +)) skipped\(skippedText.isEmpty ? "" : " (\(skippedText))"), \(failed.count) failed of \(cases.count)")
    }

    static func strings(_ v: JSONValue?) -> [String] {
        guard case .array(let a)? = v else { return [] }
        return a.compactMap { if case .string(let s) = $0 { s } else { nil } }
    }

    /// Runs one case; returns why it failed, or `nil`.
    static func run(_ c: JSONValue) -> String? {
        guard let contractJSON = c["contract"] else { return "no contract" }
        var environment: [String: String] = [:]
        if case .object(let members)? = c["env"] {
            for (k, v) in members {
                guard case .string(let s) = v else { return "env \(k) is not a string" }
                environment[k] = s
            }
        }
        let contract: ContractDocument
        do {
            contract = try ContractDocument(contract: contractJSON)
        } catch {
            return "contract rejected: \(error)"
        }
        let result = Result { () throws(ConfigurationError) in try contract.load(environment: environment) }

        if let expect = c["expect"] {
            switch result {
            case .failure(let e):
                return "expected values, got \(e)"
            case .success(let values):
                guard case .object(let expected) = expect else { return "expect is not an object" }
                var diffs: [String] = []
                for (name, want) in expected {
                    let got = values[name]?.jsonValue ?? .null
                    if !sameJSON(got, want) { diffs.append("\(name): got \(got.jsonText), want \(want.jsonText)") }
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
            // No message may contain the raw value of a secret variable.
            let output = e.description
            for spec in contract.vars where spec.secret {
                let raws = environment.filter { $0.key == spec.name || $0.key.hasPrefix(spec.name + "__") }.map(\.value)
                for raw in raws where !raw.isEmpty && output.contains(raw) {
                    return "error output contains the value of secret \(spec.name)"
                }
            }
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
