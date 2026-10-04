import Foundation

/// Runs `cue vet -c` on an exported contract against the docuconf meta-schema.
///
/// The meta-schema is read from `DOCUCONF_SPEC_CUE` (a `spec/cue` directory) or, failing that, from a
/// `docuconf-go` checkout next to this repository. `cue` is found through `CUE`, `~/go/bin/cue` or `PATH`.
/// When either is missing the check is skipped, unless `DOCUCONF_REQUIRE_VET=1` (as in CI).
enum CueVet {
    static let env = ProcessInfo.processInfo.environment
    static let packageRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    static var required: Bool { env["DOCUCONF_REQUIRE_VET"] == "1" }

    static var specDir: URL? {
        let candidates = [env["DOCUCONF_SPEC_CUE"].map { URL(fileURLWithPath: $0) },
                          packageRoot.deletingLastPathComponent().appendingPathComponent("docuconf-go/spec/cue")]
        return candidates.compactMap { $0 }.first {
            FileManager.default.fileExists(atPath: $0.appendingPathComponent("contract/contract.cue").path)
        }
    }

    static var cue: String? {
        var candidates: [String] = []
        if let c = env["CUE"] { candidates.append(c) }
        if let home = env["HOME"] { candidates.append(home + "/go/bin/cue") }
        candidates.append("/root/go/bin/cue")
        for dir in (env["PATH"] ?? "").split(separator: ":") { candidates.append(dir + "/cue") }
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    enum Outcome: Equatable {
        case passed
        case skipped(String)
        case failed(String)
    }

    static func vet(_ contract: String, package: String) throws -> Outcome {
        guard let spec = specDir else { return .skipped("meta-schema not found; set DOCUCONF_SPEC_CUE") }
        guard let cue else { return .skipped("cue not found") }
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("docuconf-vet-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: dir) }
        try fm.createDirectory(at: dir.appendingPathComponent("svc"), withIntermediateDirectories: true)
        try fm.copyItem(at: spec.appendingPathComponent("cue.mod"), to: dir.appendingPathComponent("cue.mod"))
        try fm.copyItem(at: spec.appendingPathComponent("contract"), to: dir.appendingPathComponent("contract"))
        try contract.write(to: dir.appendingPathComponent("svc/contract.cue"), atomically: true, encoding: .utf8)
        let (status, output) = try run(cue, ["vet", "-c", "./svc"], in: dir)
        return status == 0 ? .passed : .failed(output)
    }

    /// `cue export` of the contract, as JSON, for data-level comparisons.
    static func export(_ contract: String) throws -> String? {
        guard let spec = specDir, let cue else { return nil }
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("docuconf-export-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: dir) }
        try fm.createDirectory(at: dir.appendingPathComponent("svc"), withIntermediateDirectories: true)
        try fm.copyItem(at: spec.appendingPathComponent("cue.mod"), to: dir.appendingPathComponent("cue.mod"))
        try fm.copyItem(at: spec.appendingPathComponent("contract"), to: dir.appendingPathComponent("contract"))
        try contract.write(to: dir.appendingPathComponent("svc/contract.cue"), atomically: true, encoding: .utf8)
        let (status, output) = try run(cue, ["export", "./svc"], in: dir)
        return status == 0 ? output : nil
    }

    static func run(_ executable: String, _ args: [String], in dir: URL) throws -> (Int32, String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: executable)
        p.arguments = args
        p.currentDirectoryURL = dir
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        try p.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (p.terminationStatus, String(decoding: data, as: UTF8.self))
    }
}
