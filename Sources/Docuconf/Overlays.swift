public import Configuration
import DocuconfCore
import Foundation

extension Docuconf {
    /// One swift-configuration provider per declared overlay (SPEC §4.7), for apps that compose their own
    /// `ConfigReader`. Put them after the environment and before your baked-in file providers, so the
    /// precedence is base file < overlay < environment (the first provider with a value wins):
    ///
    /// ```swift
    /// let reader = ConfigReader(providers: [EnvironmentVariablesProvider()]
    ///     + (try await Docuconf.overlayProviders(for: GatewayConfig.self))
    ///     + [try await FileProvider<JSONSnapshot>(filePath: "/app/config/gateway.json")])
    /// let config = try await Docuconf.load(GatewayConfig.self, from: reader)
    /// ```
    ///
    /// Each overlay is a `FileProvider<JSONSnapshot>` or `FileProvider<YAMLSnapshot>` that allows a missing
    /// file. `DOCUCONF_FILE_ROOT` is prepended to its path.
    ///
    /// - Throws: ``DeclarationError`` if the declaration is invalid or an overlay is in the app's own
    ///   directory; ``ConfigurationError`` (`file_malformed`, `file_unreadable`) if an overlay that exists
    ///   cannot be read. ``load(_:dotEnvPath:files:options:)`` reports the latter together with every other
    ///   problem instead.
    public static func overlayProviders<C: DocuconfConfig>(for type: C.Type, options: LoadOptions = LoadOptions()) async throws -> [any ConfigProvider] {
        let (providers, violations) = try await OverlayLoader.providers(for: Declaration(type), options: options)
        if !violations.isEmpty {
            let error = ConfigurationError(violations: violations)
            writeTerminationLog(error, options: options)
            throw error
        }
        return providers
    }
}

enum OverlayLoader {
    static func providers(for declaration: Declaration, options: LoadOptions) async throws -> ([any ConfigProvider], [Violation]) {
        var providers: [any ConfigProvider] = []
        var violations: [Violation] = []
        for overlay in declaration.overlays {
            let path = options.rooted(overlay.path)
            try checkNotInAppDirectory(overlay, path: path, appDirectory: options.appDirectory)
            switch await provider(overlay, path: path) {
            case .success(let p): providers.append(p)
            case .failure(let v): violations.append(v)
            }
        }
        return (providers, violations)
    }

    static func provider(_ overlay: ConfigOverlay, path: String) async -> Result<any ConfigProvider, Violation> {
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) {
            if isDirectory.boolValue {
                return .failure(Violation(.fileUnreadable, overlay.name, "overlay \(path) is a directory, not a file"))
            }
            if !FileManager.default.isReadableFile(atPath: path) {
                return .failure(Violation(.fileUnreadable, overlay.name, "overlay \(path) is not readable by this process"))
            }
        }
        do {
            switch overlay.format {
            case .yaml:
                return .success(try await FileProvider<YAMLSnapshot>(filePath: .init(path), allowMissing: true))
            default:
                return .success(try await FileProvider<JSONSnapshot>(filePath: .init(path), allowMissing: true))
            }
        } catch {
            // Overlays hold no secrets (the platform puts them in the environment), so the parser's message,
            // which may name a key, is safe to show.
            return .failure(Violation(.fileMalformed, overlay.name, "overlay \(path) is not valid \(overlay.format.rawValue.uppercased()): \(error)"))
        }
    }

    /// The platform mounts the overlay's directory, which hides whatever the image has there (SPEC §4.7).
    static func checkNotInAppDirectory(_ overlay: ConfigOverlay, path: String, appDirectory: String?) throws {
        guard let appDirectory else { return }
        let dir = URL(fileURLWithPath: path).deletingLastPathComponent().resolvingSymlinksInPath().path
        let app = URL(fileURLWithPath: appDirectory).resolvingSymlinksInPath().path
        if dir == app {
            throw DeclarationError(problems: [
                "overlay \(overlay.name): \(overlay.path) is in the app's own directory; mounting it would hide the app's files. Use a directory of its own, such as /etc/<app>/overlay",
            ])
        }
    }
}
