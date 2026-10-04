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

    public init(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        now: @escaping @Sendable () -> Date = { Date() },
        warn: @escaping @Sendable (String) -> Void = { Docuconf.printToStandardError("docuconf: warning: " + $0) },
        decoders: any StructuredDecoding = DefaultDecoding()
    ) {
        self.environment = environment
        self.now = now
        self.warn = warn
        self.decoders = decoders
    }

    /// `DOCUCONF_FILE_ROOT`: a directory prepended to every absolute file input path, for local
    /// development and tests (SPEC §11.1).
    public var fileRoot: String? {
        environment["DOCUCONF_FILE_ROOT"].flatMap { $0.isEmpty ? nil : $0 }
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
    public static func load<C: DocuconfConfig>(_ type: C.Type = C.self, from reader: ConfigReader, options: LoadOptions = LoadOptions()) async throws -> C {
        let instance = C()
        let declaration = try Declaration(instance: instance)
        for w in declaration.warnings { options.warn(w) }

        var violations: [Violation] = []
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
    /// - Parameter dotEnvPath: An optional `.env` file for local development. Real environment variables
    ///   override it (SPEC §11.2 item 4).
    public static func load<C: DocuconfConfig>(_ type: C.Type = C.self, dotEnvPath: String? = nil, options: LoadOptions = LoadOptions()) async throws -> C {
        let secrets = Set(try Declaration(type).vars.filter(\.secret).map(\.name))
        var providers: [any ConfigProvider] = [
            EnvironmentVariablesProvider(environmentVariables: options.environment, secretsSpecifier: .specific(secrets))
        ]
        if let dotEnvPath {
            providers.append(try await EnvironmentVariablesProvider(environmentFilePath: .init(dotEnvPath), allowMissing: true, secretsSpecifier: .specific(secrets)))
        }
        return try await load(type, from: ConfigReader(providers: providers), options: options)
    }

    static func writeTerminationLog(_ error: ConfigurationError, options: LoadOptions) {
        guard let path = options.terminationLogPath else { return }
        // Kubernetes keeps the first 4096 bytes; a failure to write must not hide the real error.
        try? Data(error.description.utf8.prefix(4096)).write(to: URL(fileURLWithPath: path))
    }

    /// Writes a line to standard error.
    public static func printToStandardError(_ message: String) {
        FileHandle.standardError.write(Data((message + "\n").utf8))
    }
}
