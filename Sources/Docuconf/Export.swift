import DocuconfCore
import Foundation

extension Docuconf {
    /// The contract (`contract.cue`) for a configuration struct. See ``Contract/cue(for:name:appVersion:package:)``.
    public static func contract<C: DocuconfConfig>(for type: C.Type, name: String, appVersion: String? = nil, package: String? = nil) throws -> String {
        try Contract.cue(for: type, name: name, appVersion: appVersion, package: package)
    }

    /// Exports the contract and exits when the process was started with `docuconf-export` as its first
    /// argument; otherwise returns and lets the app start. Call it first thing in `main`:
    ///
    /// ```swift
    /// Docuconf.exportIfRequested(AppConfig.self, name: "gateway")
    /// ```
    ///
    /// ```sh
    /// swift run Gateway docuconf-export --out contract.cue --app-version "$(git rev-parse HEAD)"
    /// ```
    ///
    /// Options: `--out <file>` (default: standard output), `--app-version <v>`, `--package <name>`.
    /// No environment is read and no file input is checked, so it runs in CI without production values.
    public static func exportIfRequested<C: DocuconfConfig>(_ type: C.Type, name: String, arguments: [String] = CommandLine.arguments) {
        let args = Array(arguments.dropFirst())
        guard args.first == "docuconf-export" else { return }
        var out: String?
        var appVersion: String?
        var package: String?
        var i = 1
        while i < args.count {
            let value = i + 1 < args.count ? args[i + 1] : nil
            switch args[i] {
            case "--out", "-o": out = value
            case "--app-version": appVersion = value
            case "--package": package = value
            default:
                printToStandardError("docuconf-export: unknown option \(args[i])")
                exit(2)
            }
            if value == nil {
                printToStandardError("docuconf-export: \(args[i]) needs a value")
                exit(2)
            }
            i += 2
        }
        do {
            let declaration = try Declaration(type)
            for w in declaration.warnings { printToStandardError("docuconf: warning: " + w) }
            let text = try Contract.cue(for: declaration, name: name, appVersion: appVersion, package: package)
            if let out {
                try Data(text.utf8).write(to: URL(fileURLWithPath: out))
            } else {
                FileHandle.standardOutput.write(Data(text.utf8))
            }
            exit(0)
        } catch {
            printToStandardError("\(error)")
            exit(1)
        }
    }
}
