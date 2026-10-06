import Foundation

/// A configuration struct: properties declared with ``Env`` and ``FileInput``.
///
/// ```swift
/// struct AppConfig: DocuconfConfig {
///     @Env("http.port", "HTTP listen port", .range(1...65535)) var port = 8080
/// }
/// ```
///
/// The struct needs an `init()`, which Swift synthesizes when every property has a wrapper or a value.
public protocol DocuconfConfig: Sendable {
    init()
    /// Config-file overlays the platform may mount (SPEC §4.7). None by default.
    static var overlays: [ConfigOverlay] { get }
}

extension DocuconfConfig {
    public static var overlays: [ConfigOverlay] { [] }
}

/// The inputs a ``DocuconfConfig`` declares, read by reflection, and checked for mistakes in the declaration
/// itself (SPEC §11.2 item 2).
public struct Declaration: Sendable {
    public let vars: [VarSpec]
    public let files: [FileSpec]
    public let overlays: [ConfigOverlay]
    /// Non-fatal findings, such as variable names that look like feature flags (SPEC §10).
    public let warnings: [String]

    package let envInputs: [any AnyEnv]
    package let fileInputs: [any AnyFileInput]

    /// Reads and checks the declaration of `C`.
    public init<C: DocuconfConfig>(_ type: C.Type) throws {
        try self.init(instance: C())
    }

    package init(instance: some DocuconfConfig) throws {
        var envs: [any AnyEnv] = []
        var files: [any AnyFileInput] = []
        for child in Mirror(reflecting: instance).children {
            if let e = child.value as? any AnyEnv { envs.append(e) }
            if let f = child.value as? any AnyFileInput { files.append(f) }
        }
        self.envInputs = envs
        self.fileInputs = files
        self.vars = envs.map(\.spec)
        self.files = files.map(\.spec)
        self.overlays = type(of: instance).overlays
        let (problems, warnings) = Self.validate(vars: vars, files: self.files, overlays: overlays)
        self.warnings = warnings
        if !problems.isEmpty { throw DeclarationError(problems: problems) }
    }

    static let reservedDirs: Set<String> = [
        "/", "/app", "/bin", "/boot", "/dev", "/etc", "/etc/pki", "/etc/ssl",
        "/etc/ssl/certs", "/home", "/lib", "/lib64", "/opt", "/proc", "/root",
        "/run", "/sbin", "/srv", "/sys", "/tmp", "/usr", "/usr/lib", "/usr/local",
        "/usr/share", "/var", "/var/lib", "/var/run",
    ]

    /// The directory a file input is mounted at: its own path for `tls`, otherwise its parent.
    public static func mountDirectory(_ f: FileSpec) -> String {
        if f.type == .tls { return f.path }
        let parent = (f.path as NSString).deletingLastPathComponent
        return parent.isEmpty ? "/" : parent
    }

    package static func validate(vars: [VarSpec], files: [FileSpec], overlays: [ConfigOverlay] = []) -> (problems: [String], warnings: [String]) {
        var problems: [String] = []
        var warnings: [String] = []
        var seen: [String: String] = [:]

        for v in vars {
            let n = v.name
            problems += v.problems
            if !EnvName.isValid(n) {
                problems.append("\(n): key \"\(v.key)\" does not map to a valid variable name (^[A-Z][A-Z0-9_]*$)")
            }
            if let other = seen[n] {
                problems.append("\(n): declared twice (keys \"\(other)\" and \"\(v.key)\")")
            }
            seen[n] = v.key
            if v.description.unicodeScalars.count < 5 {
                problems.append("\(n): description must be at least 5 characters")
            }
            if v.required && v.defaultValue != nil { problems.append("\(n): a required variable cannot have a default") }
            if v.secret && v.defaultValue != nil {
                problems.append("\(n): a secret cannot have a default (it would ship in the image and the contract)")
            }
            if v.secret && v.examples != nil { problems.append("\(n): a secret cannot have examples") }
            if let p = v.pattern, let why = RE2.problem(in: p) { problems.append("\(n): pattern \(p) \(why)") }
            if let a = v.minLength, let b = v.maxLength, a > b { problems.append("\(n): minLength \(a) is above maxLength \(b)") }
            if let a = v.minLength, a < 0 { problems.append("\(n): minLength cannot be negative") }
            if let a = v.minItems, let b = v.maxItems, a > b { problems.append("\(n): minItems \(a) is above maxItems \(b)") }
            if let a = v.min?.asDouble, let b = v.max?.asDouble, a > b { problems.append("\(n): min is above max") }
            if case .double(let d)? = v.min, !d.isFinite { problems.append("\(n): min must be finite") }
            if case .double(let d)? = v.max, !d.isFinite { problems.append("\(n): max must be finite") }
            for d in [v.minDuration, v.maxDuration].compactMap({ $0 }) where d < .zero {
                problems.append("\(n): duration bounds cannot be negative")
            }
            if let a = v.minDuration, let b = v.maxDuration, a > b { problems.append("\(n): min duration is above max") }
            if v.type == .enum, v.values?.isEmpty ?? true { problems.append("\(n): an enum needs at least one case") }
            if v.schemes?.isEmpty == true { problems.append("\(n): schemes cannot be empty") }
            if let d = v.defaultParsed {
                if case .duration(let dur) = d, dur < .zero {
                    problems.append("\(n): default cannot be negative")
                } else if case .double(let x) = d, !x.isFinite {
                    problems.append("\(n): default must be finite")
                } else {
                    for violation in v.check(d) {
                        problems.append("\(n): default \(v.defaultValue?.jsonText ?? "") violates its own constraints: \(violation.message)")
                    }
                }
            }
            if let r = v.deprecated?.replacedBy, !EnvName.isValid(r) {
                problems.append("\(n): deprecated.replacedBy \(r) is not a valid variable name")
            }
            if EnvName.looksLikeFeatureFlag(n) {
                warnings.append("\(n) looks like a feature flag. Flags that change without a rollout belong in a flag service (OpenFeature), not the environment (SPEC §10).")
            }
        }

        let varsByName = Dictionary(vars.map { ($0.name, $0) }, uniquingKeysWith: { a, _ in a })
        var fileNames = Set<String>()
        var mounts: [String: String] = [:]
        var pathEnvs: [String: String] = [:]
        for f in files {
            let n = f.name
            problems += f.problems
            if !EnvName.isValidInputName(n) {
                problems.append("\(n): file input names must be DNS labels (^[a-z]([-a-z0-9]{0,40}[a-z0-9])?$)")
            }
            if !fileNames.insert(n).inserted { problems.append("\(n): file input declared twice") }
            if f.description.unicodeScalars.count < 5 { problems.append("\(n): description must be at least 5 characters") }
            if !isAbsoluteNormalized(f.path) {
                problems.append("\(n): path \(f.path) must be absolute and normalised (no '.', '..', '//' or trailing '/')")
            }
            let mount = mountDirectory(f)
            if reservedDirs.contains(mount) {
                problems.append("\(n): would be mounted at \(mount), which hides a directory the image needs; choose a dedicated directory")
            }
            if let other = mounts[mount] { problems.append("\(n): shares mount directory \(mount) with \(other)") }
            mounts[mount] = n
            if let pe = f.pathEnv {
                if !EnvName.isValid(pe) { problems.append("\(n): pathEnv \(pe) is not a valid variable name") }
                if varsByName[pe] != nil { problems.append("\(n): pathEnv \(pe) must not also be declared as a variable") }
                if let other = pathEnvs[pe] { problems.append("\(n): pathEnv \(pe) is also used by \(other)") }
                pathEnvs[pe] = n
            }
            if let m = f.maxSize, m <= 0 { problems.append("\(n): maxSize must be positive") }
            if let m = f.minCertificates, m < 1 { problems.append("\(n): minCertificates must be at least 1") }
            if let p = f.pattern, let why = RE2.problem(in: p) { problems.append("\(n): pattern \(p) \(why)") }
            if let a = f.minLength, let b = f.maxLength, a > b { problems.append("\(n): minLength \(a) is above maxLength \(b)") }
            if let d = f.minRemaining, d < .zero { problems.append("\(n): minRemaining cannot be negative") }
            if f.format == .toml { problems.append("\(n): TOML config files are not supported by this SDK yet; use JSON or YAML") }
            if let pv = f.passwordVar {
                if let v = varsByName[pv] {
                    if !v.secret { problems.append("\(n): passwordVar \(pv) must be a secret variable") }
                } else {
                    problems.append("\(n): passwordVar \(pv) is not a declared variable")
                }
            }
        }
        var overlayNames = Set<String>()
        for o in overlays {
            let n = "overlay \(o.name)"
            problems += o.problems
            if !EnvName.isValidInputName(o.name) {
                problems.append("\(n): overlay names must be DNS labels (^[a-z]([-a-z0-9]{0,40}[a-z0-9])?$)")
            }
            if !overlayNames.insert(o.name).inserted { problems.append("\(n): declared twice") }
            if let d = o.description, d.unicodeScalars.count < 5 { problems.append("\(n): description must be at least 5 characters") }
            if !isAbsoluteNormalized(o.path) {
                problems.append("\(n): path \(o.path) must be absolute and normalised (no '.', '..', '//' or trailing '/')")
            }
            let mount = o.mountDirectory
            if reservedDirs.contains(mount) {
                problems.append("\(n): would be mounted at \(mount), which hides a directory the image needs; choose a dedicated directory")
            }
            if let other = mounts[mount] { problems.append("\(n): shares mount directory \(mount) with \(other)") }
            mounts[mount] = n
            if o.format == .toml { problems.append("\(n): TOML overlays are not supported; swift-configuration reads JSON and YAML") }
            if o.reload == .watch {
                problems.append("\(n): reload: watch is not supported; docuconf reads variables once at boot, so declare .restart and let a changed overlay roll the pods")
            }
        }
        return (problems, warnings)
    }

    static func isAbsoluteNormalized(_ p: String) -> Bool {
        guard p.hasPrefix("/"), p.count > 1, !p.hasSuffix("/"), !p.contains("//") else { return false }
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._/-")
        guard p.unicodeScalars.allSatisfy(allowed.contains) else { return false }
        return !p.split(separator: "/").contains { $0 == "." || $0 == ".." }
    }
}
