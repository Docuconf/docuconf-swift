import Foundation

/// Runs `cue vet -c` on an exported contract against the docuconf meta-schema.
///
/// The meta-schema is read from `DOCUCONF_SPEC_CUE` (a `spec/cue` directory) or, failing that, from a
/// `docuconf-go` checkout next to this repository. `cue` is found through `CUE`, `~/go/bin/cue` or `PATH`.
/// When either is missing the check is skipped, unless `DOCUCONF_REQUIRE_VET=1` (as in CI).
public enum CueVet {
    public static let env = ProcessInfo.processInfo.environment
    public static let packageRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    public static var required: Bool { env["DOCUCONF_REQUIRE_VET"] == "1" }

    public static var specDir: URL? {
        let candidates = [env["DOCUCONF_SPEC_CUE"].map { URL(fileURLWithPath: $0) },
                          packageRoot.deletingLastPathComponent().appendingPathComponent("docuconf-go/spec/cue")]
        return candidates.compactMap { $0 }.first {
            FileManager.default.fileExists(atPath: $0.appendingPathComponent("contract/contract.cue").path)
        }
    }

    public static var cue: String? {
        var candidates: [String] = []
        if let c = env["CUE"] { candidates.append(c) }
        if let home = env["HOME"] { candidates.append(home + "/go/bin/cue") }
        candidates.append("/root/go/bin/cue")
        for dir in (env["PATH"] ?? "").split(separator: ":") { candidates.append(dir + "/cue") }
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    public enum Outcome: Equatable {
        case passed
        case skipped(String)
        case failed(String)
    }

    public static func vet(_ contract: String, package: String) throws -> Outcome {
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

    /// Renders a config-file overlay the way the platform does: `contract.#Validate` and `contract.#Render`
    /// from the meta-schema, on the exported contract (package `svc`), with `overlayValues` (CUE fields, such
    /// as `PORT: 8080`) in the overlay and `values` in the environment. Returns the file the platform would
    /// mount, or `nil` when cue or the meta-schema is missing; throws ``RenderError`` when the platform would
    /// refuse the values.
    public static func renderOverlay(_ contract: String, overlay: String, fileName: String, overlayValues: String, values: String = "") throws -> String? {
        guard let spec = specDir, let cue else { return nil }
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("docuconf-render-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: dir) }
        for sub in ["svc", "platform"] {
            try fm.createDirectory(at: dir.appendingPathComponent(sub), withIntermediateDirectories: true)
        }
        try fm.copyItem(at: spec.appendingPathComponent("cue.mod"), to: dir.appendingPathComponent("cue.mod"))
        try fm.copyItem(at: spec.appendingPathComponent("contract"), to: dir.appendingPathComponent("contract"))
        try contract.write(to: dir.appendingPathComponent("svc/contract.cue"), atomically: true, encoding: .utf8)
        let render = """
            package platform

            import (
            \t"docuconf.dev/contract"
            \tapp "docuconf.dev/svc"
            )

            _values: {
            \(values)
            }
            _overlays: \(overlay): {
            \(overlayValues)
            }
            check: contract.#Validate & {contract: app, values: _values, overlays: _overlays}
            rendered: contract.#Render & {contract: app, values: _values, overlays: _overlays}
            file: rendered.configMaps[0].data["\(fileName)"]

            """
        try render.write(to: dir.appendingPathComponent("platform/render.cue"), atomically: true, encoding: .utf8)
        let (vetStatus, vetOutput) = try run(cue, ["vet", "-c", "./platform"], in: dir)
        guard vetStatus == 0 else { throw RenderError(output: vetOutput) }
        let (status, output) = try run(cue, ["export", "./platform", "-e", "file", "--out", "text"], in: dir)
        guard status == 0 else { throw RenderError(output: output) }
        return output
    }

    public struct RenderError: Error, CustomStringConvertible {
        public var output: String
        public var description: String { "cue export failed:\n\(output)" }
    }

    /// `cue export` of the contract, as JSON, for data-level comparisons.
    public static func export(_ contract: String) throws -> String? {
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

    public static func run(_ executable: String, _ args: [String], in dir: URL) throws -> (Int32, String) {
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
