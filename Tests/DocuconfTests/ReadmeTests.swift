import Docuconf
import Foundation
import Testing

/// Every `swift` and `text` block in README.md must be preceded by `<!-- snippet: path[#region] -->` and be exactly
/// that file, or the lines between `// snippet:<region>` and `// snippet:end` in it (several such pieces of one
/// region are joined, each dedented). The files are compiled or run in CI, so the README shows code that works.
/// A block may instead say `<!-- checked-by: script -->` when a script checks it.
@Suite struct ReadmeTests {
    static let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    struct Block { var marker: String?; var language: String; var body: String; var line: Int }

    static func blocks(in text: String) -> [Block] {
        let lines = text.components(separatedBy: "\n")
        var out: [Block] = []
        var i = 0
        while i < lines.count {
            let line = lines[i]
            if line.hasPrefix("```"), line.count > 3 {
                let language = String(line.dropFirst(3))
                var j = i + 1
                var body: [String] = []
                while j < lines.count, lines[j] != "```" { body.append(lines[j]); j += 1 }
                let previous = i > 0 ? lines[i - 1].trimmingCharacters(in: .whitespaces) : ""
                let marker = previous.hasPrefix("<!--") ? previous : nil
                out.append(Block(marker: marker, language: language, body: body.joined(separator: "\n"), line: i + 1))
                i = j + 1
            } else {
                i += 1
            }
        }
        return out
    }

    static func region(_ name: String?, of text: String) -> String? {
        let lines = text.components(separatedBy: "\n")
        guard let name else {
            return lines.filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("// snippet:") }
                .joined(separator: "\n").trimmingCharacters(in: .newlines)
        }
        var pieces: [[String]] = []
        var current: [String]?
        for line in lines {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t == "// snippet:\(name)" {
                current = []
            } else if t == "// snippet:end", let c = current {
                pieces.append(c)
                current = nil
            } else if current != nil {
                current!.append(line)
            }
        }
        guard !pieces.isEmpty else { return nil }
        return pieces.map(dedent).joined(separator: "\n").trimmingCharacters(in: .newlines)
    }

    static func dedent(_ lines: [String]) -> String {
        let indent = lines.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            .map { $0.prefix(while: { $0 == " " }).count }.min() ?? 0
        return lines.map { $0.count >= indent ? String($0.dropFirst(indent)) : $0.trimmingCharacters(in: .whitespaces) }
            .joined(separator: "\n")
    }

    @Test func everySwiftAndTextBlockIsACheckedFile() throws {
        let readme = try String(contentsOf: Self.root.appendingPathComponent("README.md"), encoding: .utf8)
        let checked = Self.blocks(in: readme).filter { $0.language == "swift" || $0.language == "text" }
        #expect(checked.count >= 10)
        for block in checked {
            guard let marker = block.marker else {
                Issue.record("README.md:\(block.line): a \(block.language) block without a <!-- snippet: ... --> marker")
                continue
            }
            if marker.hasPrefix("<!-- checked-by: ") {
                let script = marker.dropFirst("<!-- checked-by: ".count).dropLast(" -->".count)
                #expect(FileManager.default.fileExists(atPath: Self.root.appendingPathComponent(String(script)).path), "README.md:\(block.line)")
                continue
            }
            guard marker.hasPrefix("<!-- snippet: "), marker.hasSuffix(" -->") else {
                Issue.record("README.md:\(block.line): unknown marker \(marker)")
                continue
            }
            let ref = marker.dropFirst("<!-- snippet: ".count).dropLast(" -->".count).split(separator: "#", maxSplits: 1).map(String.init)
            let source = try String(contentsOf: Self.root.appendingPathComponent(ref[0]), encoding: .utf8)
            let expected = try #require(Self.region(ref.count > 1 ? ref[1] : nil, of: source), "README.md:\(block.line): no region \(ref)")
            #expect(block.body == expected, "README.md:\(block.line) differs from \(ref.joined(separator: "#"))")
        }
    }

    @Test func theInjectedSecretMessageIsWhatLoadSays() async throws {
        struct DB: DocuconfConfig {
            @Env("database.url", "Primary database", .secret) var databaseURL: URL
        }
        let readme = try String(contentsOf: Self.root.appendingPathComponent("README.md"), encoding: .utf8)
        let block = try #require(Self.blocks(in: readme).first { $0.body.contains("unresolved vault: reference") })
        #expect(block.marker == "<!-- checked-by: Tests/DocuconfTests/ReadmeTests.swift -->")
        let error = await #expect(throws: ConfigurationError.self) {
            try await Docuconf.load(DB.self, environment: ["DATABASE_URL": "vault:secret/data/db#url"])
        }
        #expect(error?.violations.map(\.description) == [block.body])
    }

    @Test func theInstallBlockIsACompleteManifestOnTheMainBranch() throws {
        let readme = try String(contentsOf: Self.root.appendingPathComponent("README.md"), encoding: .utf8)
        let install = try #require(Self.blocks(in: readme).first { $0.marker == "<!-- checked-by: scripts/check-readme-install.sh -->" })
        #expect(install.body.hasPrefix("// swift-tools-version:"))
        #expect(install.body.contains(#".package(url: "https://github.com/docuconf/docuconf-swift", branch: "main")"#))
        #expect(install.body.contains(#".product(name: "Docuconf", package: "docuconf-swift")"#))
    }
}
