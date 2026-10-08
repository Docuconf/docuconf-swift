@_exported import DocuconfCore
public import Configuration
import Foundation

/// Settings for ``Docuconf/load(_:from:options:)``.
public struct LoadOptions: Sendable {
    /// The environment. Defaults to the process environment, which is only read, never changed.
    ///
    /// - With ``Docuconf/load(_:dotEnvPath:files:options:)`` (no reader), configuration values are read from it,
    ///   so a test can pass a dictionary and never touch the process environment.
    /// - With ``Docuconf/load(_:from:options:)``, values come from the `ConfigReader`, and this is used only for
    ///   `DOCUCONF_FILE_ROOT`, `DOCUCONF_TERMINATION_LOG` and the warnings about misspelled names.
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
    /// when that file exists. `DOCUCONF_TERMINATION_LOG` set to an empty string writes no log.
    public var terminationLogPath: String? {
        if let p = environment["DOCUCONF_TERMINATION_LOG"] { return p.isEmpty ? nil : p }  // empty: no log
        return FileManager.default.fileExists(atPath: "/dev/termination-log") ? "/dev/termination-log" : nil
    }
}

/// Loads and validates configuration at boot.
public enum Docuconf {
    /// Reads every declared variable through `reader`, checks every file input, and returns the typed
    /// configuration. Throws ``ConfigurationError`` listing **all** problems, after writing them to the
    /// Kubernetes termination log, or ``DeclarationError`` if the declaration itself is wrong.
    ///
    /// In `main`, use ``loadOrExit(_:from:options:)`` instead: a `throws` escaping top-level code or an
    /// `async throws` `main` crashes the process with a backtrace. Use `load` in tests:
    ///
    /// ```swift
    /// await #expect(throws: ConfigurationError.self) {
    ///     try await Docuconf.load(AppConfig.self, from: ConfigReader(provider: InMemoryProvider(values: ["http.port": 0])))
    /// }
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
        let declared = Set(declaration.vars.map(\.name) + declaration.files.compactMap(\.pathEnv))
        for w in TypoHint.warnings(declared: declared, environment: options.environment) { options.warn(w) }

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

    /// Loads from the given environment only, for tests: the process environment is neither read nor changed,
    /// no `.env` file is read, and nothing keeps running afterwards.
    ///
    /// ```swift
    /// let config = try await Docuconf.load(AppConfig.self, environment: ["DATABASE_URL": "postgres://db/app"])
    /// ```
    ///
    /// - Parameters:
    ///   - environment: The variables, by environment name (`HTTP_PORT`).
    ///   - fileRoot: Prepended to every absolute file input path, as `DOCUCONF_FILE_ROOT` is.
    public static func load<C: DocuconfConfig>(
        _ type: C.Type = C.self, environment: [String: String], fileRoot: String? = nil, warn: @escaping @Sendable (String) -> Void = { _ in }
    ) async throws -> C {
        var env = environment
        if let fileRoot { env["DOCUCONF_FILE_ROOT"] = fileRoot }
        // An explicit environment never writes to /dev/termination-log unless it asks to.
        if env["DOCUCONF_TERMINATION_LOG"] == nil { env["DOCUCONF_TERMINATION_LOG"] = "" }
        return try await load(type, options: LoadOptions(environment: env, warn: warn, appDirectory: nil))
    }

    /// Like ``load(_:from:options:)``, but on a configuration problem it prints the problems to standard error
    /// and exits with status 1, with no backtrace. This is the call for `main`:
    ///
    /// ```swift
    /// let config = await Docuconf.loadOrExit(AppConfig.self, from: reader)
    /// ```
    ///
    /// ```
    /// docuconf: 2 configuration problems:
    ///   - HTTP_PORT [out_of_range]: is below min 1 (got "0")
    ///   - DATABASE_URL [missing_required]: is required but not set (Primary Postgres connection string)
    /// ```
    ///
    /// The problems also go to the termination log, so `kubectl describe pod` shows them.
    public static func loadOrExit<C: DocuconfConfig>(_ type: C.Type = C.self, from reader: ConfigReader, options: LoadOptions = LoadOptions()) async -> C {
        await orExit(options: options) { try await load(type, from: reader, options: options) }
    }

    /// Like ``load(_:dotEnvPath:files:options:)``, but on a configuration problem it prints the problems to
    /// standard error and exits with status 1, with no backtrace. This is the call for `main`:
    ///
    /// ```swift
    /// let config = await Docuconf.loadOrExit(AppConfig.self)
    /// ```
    public static func loadOrExit<C: DocuconfConfig>(
        _ type: C.Type = C.self, dotEnvPath: String? = nil, files: [any ConfigProvider] = [], options: LoadOptions = LoadOptions()
    ) async -> C {
        await orExit(options: options) { try await load(type, dotEnvPath: dotEnvPath, files: files, options: options) }
    }

    /// Runs `body`; on a docuconf error prints it once and exits 1. The exit is injectable for tests.
    static func orExit<C>(options: LoadOptions, exit: (Int32) -> Never = { Foundation.exit($0) }, _ body: () async throws -> C) async -> C {
        do {
            return try await body()
        } catch let e as ConfigurationError {
            // `load` has written the termination log already.
            printToStandardError(e.description)
        } catch let e as DeclarationError {
            writeTerminationLog(e.description, options: options)
            printToStandardError(e.description)
        } catch {
            // Only a provider can throw anything else (an unreadable `.env` file, a broken overlay provider).
            let text = "docuconf: configuration could not be loaded: \(error)"
            writeTerminationLog(text, options: options)
            printToStandardError(text)
        }
        exit(1)
    }

    static func writeTerminationLog(_ error: ConfigurationError, options: LoadOptions) {
        writeTerminationLog(error.description, options: options)
    }

    static func writeTerminationLog(_ text: String, options: LoadOptions) {
        guard let path = options.terminationLogPath else { return }
        // Kubernetes keeps the first 4096 bytes; a failure to write must not hide the real error.
        try? Data(text.utf8.prefix(4096)).write(to: URL(fileURLWithPath: path))
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
