@_exported import DocuconfCore
public import Configuration
import Foundation

/// Settings for ``Docuconf/load(_:from:options:)``.
public struct LoadOptions: Sendable {
    /// The process environment, for `DOCUCONF_FILE_ROOT` and `DOCUCONF_TERMINATION_LOG`.
    /// Configuration values themselves are read through the `ConfigReader`.
    public var environment: [String: String]
    /// The clock certificate checks use.
    public var now: @Sendable () -> Date
    /// Receives warnings: deprecated variables that are set, names that look like feature flags,
    /// secrets that end in a newline. Defaults to standard error.
    public var warn: @Sendable (String) -> Void
    /// Decodes config files. The default handles JSON and YAML.
    public var decoders: any StructuredDecoding
    /// The directory the app ships in. A config-file overlay may not be there, because mounting it would
    /// hide the app's files (SPEC §4.7). Defaults to the executable's directory; `nil` skips the check.
    public var appDirectory: String?

    public init(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        now: @escaping @Sendable () -> Date = { Date() },
        warn: @escaping @Sendable (String) -> Void = { Docuconf.printToStandardError("docuconf: warning: " + $0) },
        decoders: any StructuredDecoding = DefaultDecoding(),
        appDirectory: String? = Bundle.main.executableURL?.deletingLastPathComponent().path
    ) {
        self.environment = environment
        self.now = now
        self.warn = warn
        self.decoders = decoders
        self.appDirectory = appDirectory
    }

    /// `DOCUCONF_FILE_ROOT`: a directory prepended to every absolute file input path, for local
    /// development and tests (SPEC §11.1).
    public var fileRoot: String? {
        environment["DOCUCONF_FILE_ROOT"].flatMap { $0.isEmpty ? nil : $0 }
    }

    /// An absolute in-container path with `DOCUCONF_FILE_ROOT` prepended.
    func rooted(_ path: String) -> String {
        guard let root = fileRoot, path.hasPrefix("/") else { return path }
        return (root.hasSuffix("/") ? String(root.dropLast()) : root) + path
    }

    /// Where violations are written for Kubernetes: `DOCUCONF_TERMINATION_LOG`, or `/dev/termination-log`
    /// when that file exists.
    public var terminationLogPath: String? {
        if let p = environment["DOCUCONF_TERMINATION_LOG"], !p.isEmpty { return p }
        return FileManager.default.fileExists(atPath: "/dev/termination-log") ? "/dev/termination-log" : nil
    }
}

/// Loads and validates configuration at boot.
public enum Docuconf {
    /// Reads every declared variable through `reader`, checks every file input, and returns the typed
    /// configuration. Throws ``ConfigurationError`` listing **all** problems, after writing them to the
    /// Kubernetes termination log, or ``DeclarationError`` if the declaration itself is wrong.
    ///
    /// ```swift
    /// let reader = ConfigReader(provider: EnvironmentVariablesProvider())
    /// let config = try await Docuconf.load(AppConfig.self, from: reader)
    /// ```
    ///
    /// Config-file overlays are read only if `reader` has them: see ``overlayProviders(for:options:)``.
    public static func load<C: DocuconfConfig>(_ type: C.Type = C.self, from reader: ConfigReader, options: LoadOptions = LoadOptions()) async throws -> C {
        try await load(type, from: reader, options: options, violations: [])
    }

    static func load<C: DocuconfConfig>(_ type: C.Type, from reader: ConfigReader, options: LoadOptions, violations earlier: [Violation]) async throws -> C {
        let instance = C()
        let declaration = try Declaration(instance: instance)
        try checkTraits(declaration)
        for w in declaration.warnings { options.warn(w) }

        var violations = earlier
        var rawSecrets: [String: String] = [:]
        for input in declaration.envInputs {
            violations += VarLoader.load(input, reader: reader, options: options, rawSecrets: &rawSecrets)
        }
        let loader = FileLoader(options: options, reader: reader, rawSecrets: rawSecrets)
        for input in declaration.fileInputs {
            violations += await loader.load(input)
        }

        if !violations.isEmpty {
            let error = ConfigurationError(violations: violations)
            writeTerminationLog(error, options: options)
            throw error
        }
        return instance
    }

    /// Loads from the process environment with swift-configuration's `EnvironmentVariablesProvider`,
    /// marking declared secrets as secret so the provider redacts them too.
    ///
    /// The providers are, first match wins: the environment, the `.env` file, the declared config-file
    /// overlays (``ConfigOverlay``), then `files`. That is SPEC §4.7's precedence, base file < overlay <
    /// environment. A problem with an overlay is reported together with every other violation.
    ///
    /// ```swift
    /// let base = try await FileProvider<JSONSnapshot>(filePath: "/app/config/gateway.json")
    /// let config = try await Docuconf.load(GatewayConfig.self, files: [base])
    /// ```
    ///
    /// - Parameters:
    ///   - dotEnvPath: An optional `.env` file for local development. Real environment variables override it
    ///     (SPEC §11.2 item 4).
    ///   - files: Providers for the config files baked into the image. They come last, so the environment and
    ///     the overlays override them; among them, the first one listed wins.
    public static func load<C: DocuconfConfig>(
        _ type: C.Type = C.self, dotEnvPath: String? = nil, files: [any ConfigProvider] = [], options: LoadOptions = LoadOptions()
    ) async throws -> C {
        let declaration = try Declaration(type)
        let secrets = Set(declaration.vars.filter(\.secret).map(\.name))
        var providers: [any ConfigProvider] = [
            EnvironmentVariablesProvider(environmentVariables: options.environment, secretsSpecifier: .specific(secrets))
        ]
        if let dotEnvPath {
            providers.append(try await EnvironmentVariablesProvider(environmentFilePath: .init(dotEnvPath), allowMissing: true, secretsSpecifier: .specific(secrets)))
        }
        let (overlays, overlayViolations) = try await OverlayLoader.providers(for: declaration, options: options)
        providers += overlays
        providers += files
        return try await load(type, from: ConfigReader(providers: providers), options: options, violations: overlayViolations)
    }

    static func writeTerminationLog(_ error: ConfigurationError, options: LoadOptions) {
        guard let path = options.terminationLogPath else { return }
        // Kubernetes keeps the first 4096 bytes; a failure to write must not hide the real error.
        try? Data(error.description.utf8.prefix(4096)).write(to: URL(fileURLWithPath: path))
    }

    /// File inputs that need a check this build leaves out: TLS key pairs, CA bundles and keystores are checked
    /// with swift-certificates and swift-crypto, which are built only with the package's `TLS` trait.
    static func checkTraits(_ declaration: Declaration) throws {
        #if !TLS
        let needTLS = declaration.files.filter { [.tls, .caBundle, .keystore].contains($0.type) }
        if !needTLS.isEmpty {
            throw DeclarationError(problems: needTLS.map {
                "\($0.name): \($0.type.rawValue) inputs are checked with swift-certificates and swift-crypto, which docuconf builds only "
                    + "with its TLS trait; depend on it with .package(url: \"https://github.com/docuconf/docuconf-swift\", ..., traits: [\"TLS\"])"
            })
        }
        #endif
    }

    /// Writes a line to standard error.
    public static func printToStandardError(_ message: String) {
        FileHandle.standardError.write(Data((message + "\n").utf8))
    }
}
