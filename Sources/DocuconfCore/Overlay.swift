import Foundation

/// A config-file overlay (SPEC §4.7): one more file, mounted by the platform, layered between the app's
/// baked-in config files and the environment.
///
/// Declare overlays on the configuration type:
///
/// ```swift
/// struct GatewayConfig: DocuconfConfig {
///     static let overlays = [
///         ConfigOverlay("platform", "Settings the platform manages", path: "/etc/gateway/overlay/gateway.json"),
///     ]
///     @Env("http.port", "HTTP listen port") var port = 8080
/// }
/// ```
///
/// The platform writes each value at its variable's swift-configuration key (`http.port` becomes
/// `{"http": {"port": 8080}}`), which is how `FileProvider<JSONSnapshot>` reads nested keys.
public struct ConfigOverlay: Sendable, Hashable {
    /// A DNS label, unique among the overlays.
    public var name: String
    public var description: String?
    /// Where the app reads the overlay. The platform mounts its directory, so it must not hold files the
    /// app ships with.
    public var path: String
    public var format: ConfigFormat
    /// How a configuration key splits into nested keys. swift-configuration keys are dotted (`http.port`).
    public var keySeparator: String { Self.keySeparator }
    public var reload: Reload

    /// The key separator of swift-configuration's file snapshots.
    public static let keySeparator = "."

    /// Declaration problems found while building the overlay.
    public var problems: [String] = []

    /// - Parameters:
    ///   - format: JSON or YAML. Inferred from the extension (`.json`, `.yaml`, `.yml`) when omitted.
    ///   - reload: Only `.restart` is supported: docuconf reads variables once, at boot, so a changed overlay
    ///     rolls the pods. Declaring `.watch` is a declaration error.
    public init(_ name: String, _ description: String? = nil, path: String, format: ConfigFormat? = nil, reload: Reload = .restart) {
        self.name = name
        self.description = description
        self.path = path
        self.reload = reload
        if let format {
            self.format = format
        } else {
            switch (path as NSString).pathExtension.lowercased() {
            case "json": self.format = .json
            case "yaml", "yml": self.format = .yaml
            default:
                self.format = .json
                problems.append("overlay \(name): cannot tell the format of \(path) from its extension; pass format:")
            }
        }
    }

    /// The directory the platform mounts.
    public var mountDirectory: String {
        let parent = (path as NSString).deletingLastPathComponent
        return parent.isEmpty ? "/" : parent
    }
}
