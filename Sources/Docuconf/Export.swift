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
        guard let first = args.first else { return }
        if first != "docuconf-export" && first.hasPrefix("docuconf") {
            // `docuconf_export`, `docuconf-exprot`: an exporter typo must not boot the real app.
            printToStandardError("docuconf-export: unknown command \(first); did you mean docuconf-export?")
            exit(2)
        }
        guard first == "docuconf-export" else { return }
        if args.contains("--help") || args.contains("-h") {
            print(exportUsage)
            exit(0)
        }
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
                printToStandardError("docuconf-export: unknown option \(args[i])\n\n" + exportUsage)
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
                do {
                    try Data(text.utf8).write(to: URL(fileURLWithPath: out))
                } catch {
                    let dir = (out as NSString).deletingLastPathComponent
                    var isDir: ObjCBool = false
                    let reason = !dir.isEmpty && !(FileManager.default.fileExists(atPath: dir, isDirectory: &isDir) && isDir.boolValue)
                        ? "no such directory \(dir)" : "permission denied or not a regular file"
                    printToStandardError("docuconf-export: cannot write \(out): \(reason)")
                    exit(1)
                }
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

let exportUsage = """
    usage: <app> docuconf-export [--out <file>] [--app-version <version>] [--package <name>]

    Writes the app's docuconf contract (contract.cue) and exits. Reads no environment and checks no files.

      -o, --out <file>          file to write (default: standard output)
          --app-version <v>     metadata.appVersion, such as the git SHA
          --package <name>      CUE package name (default: the service name with - replaced by _)
      -h, --help                show this help
    """
