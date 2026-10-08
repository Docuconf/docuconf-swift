import Foundation

/// A type a ``FileInput`` can hold: one of the file value types, or an optional of one.
public protocol FileValue: Sendable {
    associatedtype Base: FileBaseValue
    static var isOptional: Bool { get }
    static func wrap(_ base: Base?) -> Self?
    /// The value, or `nil` for an absent optional input.
    var base: Base? { get }
}

/// The file input types (SPEC §4.6): ``ConfigFile``, ``TLSKeyPair``, ``CABundle``, ``Keystore``, ``TextFile``
/// and ``BinaryFile``.
public protocol FileBaseValue: FileValue where Base == Self {
    static var fileType: FileType { get }
    /// Adds type-specific contract fields, such as a config file's JSON Schema.
    static func describe(_ spec: inout FileSpec) throws
    /// Builds the value from a file the loader has read and checked.
    static func make(from file: LoadedFile, decoders: any StructuredDecoding) throws -> Self
}

extension FileBaseValue {
    public static var isOptional: Bool { false }
    public static func wrap(_ base: Self?) -> Self? { base }
    public var base: Self? { self }
    public static func describe(_ spec: inout FileSpec) throws {}
}

extension Optional: FileValue where Wrapped: FileBaseValue {
    public typealias Base = Wrapped
    public static var isOptional: Bool { true }
    public static func wrap(_ base: Wrapped?) -> Wrapped?? { .some(base) }
    public var base: Wrapped? { self }
}

/// The bytes of a file input, as read by the loader.
public struct LoadedFile: Sendable {
    /// The path the content was read from (after `pathEnv` and `DOCUCONF_FILE_ROOT`). For `tls`, the directory.
    public var path: String
    /// The file's content. For `tls`, `tls.crt`.
    public var data: Data
    /// For `tls`: `tls.key`.
    public var keyData: Data?
    /// For `tls`: `ca.crt`, when present.
    public var caData: Data?
    /// For `caBundle`: how many certificates the bundle holds.
    public var certificateCount: Int?
    /// The format of a `config` file.
    public var format: ConfigFormat?

    public init(path: String, data: Data, keyData: Data? = nil, caData: Data? = nil, certificateCount: Int? = nil, format: ConfigFormat? = nil) {
        self.path = path
        self.data = data
        self.keyData = keyData
        self.caData = caData
        self.certificateCount = certificateCount
        self.format = format
    }
}

/// Decodes structured config files. `DocuconfCore` handles JSON with Foundation; the server SDK adds YAML.
public protocol StructuredDecoding: Sendable {
    func decode<T: Decodable>(_ type: T.Type, from data: Data, format: ConfigFormat) throws -> T
}

/// JSON only, with Foundation's `JSONDecoder`.
public struct FoundationDecoding: StructuredDecoding {
    public init() {}

    public func decode<T: Decodable>(_ type: T.Type, from data: Data, format: ConfigFormat) throws -> T {
        guard format == .json else { throw ValueConversionError(.fileMalformed, "\(format.rawValue) files need the Docuconf server SDK") }
        return try JSONSchema.makeJSONDecoder().decode(type, from: data)
    }
}

/// Thrown by a decoding backend when the file is not well-formed in its format (as opposed to not
/// matching the app's type).
public struct MalformedFileError: Error, Sendable, CustomStringConvertible {
    public var description: String
    public init(_ description: String) { self.description = description }
}

/// A config file type that checks its own invariants after decoding. Problems are reported as
/// `schema_mismatch`.
public protocol ValidatedConfig {
    /// Returns a description of every problem; empty when valid. Must not include secret values.
    func validate() -> [String]
}

// MARK: - Value types

/// A structured config file (`type: "config"`) decoded into the app's own type `T`. The contract carries a
/// JSON Schema derived from `T`. Access `T`'s properties directly: `config.routes.items`.
@dynamicMemberLookup
public struct ConfigFile<T: Decodable & Sendable>: FileBaseValue {
    public let path: String
    public let value: T

    public init(path: String, value: T) {
        self.path = path
        self.value = value
    }

    public subscript<V>(dynamicMember keyPath: KeyPath<T, V>) -> V { value[keyPath: keyPath] }

    public static var fileType: FileType { .config }

    public static func describe(_ spec: inout FileSpec) throws {
        spec.schema = try JSONSchema.generate(T.self)
        if spec.format == nil {
            switch (spec.path as NSString).pathExtension.lowercased() {
            case "json": spec.format = .json
            case "yaml", "yml": spec.format = .yaml
            case "toml": spec.format = .toml
            default: spec.problems.append("\(spec.name): cannot infer the config format from \(spec.path); add .format(...)")
            }
        }
    }

    public static func make(from file: LoadedFile, decoders: any StructuredDecoding) throws -> Self {
        let value: T
        do {
            value = try decoders.decode(T.self, from: file.data, format: file.format ?? .json)
        } catch let e as DecodingError {
            if case .dataCorrupted(let ctx) = e, ctx.codingPath.isEmpty {
                throw ValueConversionError(.fileMalformed, "is not valid \((file.format ?? .json).rawValue): \(ctx.debugDescription)")
            }
            throw ValueConversionError(.schemaMismatch, "does not match \(T.self): \(DecodingErrorText.describe(e))")
        } catch let e as MalformedFileError {
            throw ValueConversionError(.fileMalformed, "is not valid \((file.format ?? .json).rawValue): \(e.description)")
        }
        if let v = value as? any ValidatedConfig {
            let problems = v.validate()
            if !problems.isEmpty { throw ValueConversionError(.schemaMismatch, problems.joined(separator: "; ")) }
        }
        return ConfigFile(path: file.path, value: value)
    }
}

/// A TLS key pair in the `kubernetes.io/tls` layout: `tls.crt`, `tls.key` and, with `.requireCA`, `ca.crt`.
/// The contents are PEM, ready for swift-nio-ssl (`NIOSSLCertificate.fromPEMBytes`) or Hummingbird's TLS setup.
public struct TLSKeyPair: FileBaseValue, CustomStringConvertible {
    public let directory: String
    public let certificatePEM: Data
    public let privateKeyPEM: Data
    public let caPEM: Data?

    public var certificatePath: String { directory + "/tls.crt" }
    public var privateKeyPath: String { directory + "/tls.key" }
    public var caPath: String { directory + "/ca.crt" }

    public init(directory: String, certificatePEM: Data, privateKeyPEM: Data, caPEM: Data?) {
        self.directory = directory
        self.certificatePEM = certificatePEM
        self.privateKeyPEM = privateKeyPEM
        self.caPEM = caPEM
    }

    public static var fileType: FileType { .tls }

    public static func make(from file: LoadedFile, decoders: any StructuredDecoding) throws -> Self {
        TLSKeyPair(directory: file.path, certificatePEM: file.data, privateKeyPEM: file.keyData ?? Data(), caPEM: file.caData)
    }

    /// Never prints the private key.
    public var description: String { "TLSKeyPair(\(directory))" }
}

/// One or more PEM CA certificates, for trusting private CAs.
public struct CABundle: FileBaseValue {
    public let path: String
    public let pem: Data
    public let certificateCount: Int

    public init(path: String, pem: Data, certificateCount: Int) {
        self.path = path
        self.pem = pem
        self.certificateCount = certificateCount
    }

    public static var fileType: FileType { .caBundle }

    public static func make(from file: LoadedFile, decoders: any StructuredDecoding) throws -> Self {
        CABundle(path: file.path, pem: file.data, certificateCount: file.certificateCount ?? 0)
    }
}

/// A PKCS#12 or JKS keystore. Its password is a separate secret variable (`.passwordVar`).
public struct Keystore: FileBaseValue, CustomStringConvertible {
    public let path: String
    public let data: Data

    public init(path: String, data: Data) {
        self.path = path
        self.data = data
    }

    public static var fileType: FileType { .keystore }

    public static func describe(_ spec: inout FileSpec) throws {
        if spec.keystoreFormat == nil {
            switch (spec.path as NSString).pathExtension.lowercased() {
            case "jks": spec.keystoreFormat = .jks
            default: spec.keystoreFormat = .pkcs12
            }
        }
    }

    public static func make(from file: LoadedFile, decoders: any StructuredDecoding) throws -> Self {
        Keystore(path: file.path, data: file.data)
    }

    public var description: String { "Keystore(\(path))" }
}

/// A text file, such as a licence key. Its content is UTF-8 and is not trimmed.
public struct TextFile: FileBaseValue {
    public let path: String
    public let text: String

    public init(path: String, text: String) {
        self.path = path
        self.text = text
    }

    public static var fileType: FileType { .text }

    public static func make(from file: LoadedFile, decoders: any StructuredDecoding) throws -> Self {
        guard let text = String(data: file.data, encoding: .utf8) else {
            throw ValueConversionError(.fileMalformed, "is not UTF-8 text")
        }
        return TextFile(path: file.path, text: text)
    }
}

/// Opaque bytes, such as a GeoIP database.
public struct BinaryFile: FileBaseValue {
    public let path: String
    public let data: Data

    public init(path: String, data: Data) {
        self.path = path
        self.data = data
    }

    public static var fileType: FileType { .binary }

    public static func make(from file: LoadedFile, decoders: any StructuredDecoding) throws -> Self {
        BinaryFile(path: file.path, data: file.data)
    }
}

// MARK: - Property wrapper

/// Type-erased access to a declared file input, for the loader and the exporter.
package protocol AnyFileInput: Sendable {
    var spec: FileSpec { get }
    func store(_ file: LoadedFile, decoders: any StructuredDecoding) throws
    /// Records where and how the input was loaded, for reloading.
    func setState(_ state: FileLoadState)
}

/// Where a file input was loaded from, and whatever the loader needs to load it again.
package struct FileLoadState: Sendable {
    package var path: String
    package var context: any Sendable

    package init(path: String, context: any Sendable) {
        self.path = path
        self.context = context
    }
}

/// Declares a file input: a config file, TLS key pair, CA bundle, keystore, text or binary file.
///
/// ```swift
/// @FileInput("routes", "Routing table", path: "/etc/gateway/routes/routes.json", .pathEnv("ROUTES_FILE"))
/// var routes: ConfigFile<Routes>
/// @FileInput("serving-tls", "Certificate the gateway serves HTTPS with", path: "/etc/gateway/tls",
///            .dnsNames("gateway.internal"), .minRemaining(.seconds(720 * 3600)))
/// var tls: TLSKeyPair
/// @FileInput("trusted-cas", "Private CAs to trust", path: "/etc/gateway/ca/bundle.pem") var trustedCAs: CABundle?
/// ```
///
/// A non-optional property is a **required** input; an optional one is `nil` when the file is absent.
@propertyWrapper
public struct FileInput<Value: FileValue>: AnyFileInput {
    public let spec: FileSpec
    let box: Box<Value>
    let state: Box<FileLoadState>

    public var wrappedValue: Value {
        guard let v = box.value else {
            fatalError("docuconf: file input \(spec.name) is required and was read before Docuconf.load(...) set it")
        }
        return v
    }

    /// Access to the input's contract entry and, for `reload: watch`, its updates.
    public var projectedValue: FileInputHandle<Value> { FileInputHandle(spec: spec, box: box, state: state) }

    public init(_ name: String, _ description: String, path: String, _ rules: FileRule<Value.Base>...) {
        self.init(name, description, path, rules)
    }

    /// The same, with the description labelled: `@FileInput("routes", description: "Routing table", path: ...)`.
    public init(_ name: String, description: String, path: String, _ rules: FileRule<Value.Base>...) {
        self.init(name, description, path, rules)
    }

    private init(_ name: String, _ description: String, _ path: String, _ rules: [FileRule<Value.Base>]) {
        let doc = DocText.split(description)
        var spec = FileSpec(name: name, type: Value.Base.fileType, description: doc.description, path: path)
        spec.details = doc.details
        spec.required = !Value.isOptional
        for rule in rules { rule.apply(&spec) }
        do {
            try Value.Base.describe(&spec)
        } catch {
            spec.problems.append("\(name): \(error)")
        }
        self.spec = spec
        self.box = Box(Value.wrap(nil))
        self.state = Box(nil)
    }

    package func store(_ file: LoadedFile, decoders: any StructuredDecoding) throws {
        box.value = Value.wrap(try Value.Base.make(from: file, decoders: decoders))
    }

    package func setState(_ state: FileLoadState) { self.state.value = state }
}

/// The projected value of a ``FileInput`` (`$routes`): its contract entry, and the hooks the server SDK
/// uses to reload it (`$routes.changes(...)`).
public struct FileInputHandle<Value: FileValue>: Sendable {
    public let spec: FileSpec
    package let box: Box<Value>
    package let state: Box<FileLoadState>

    /// The current value.
    public var value: Value? { box.value }
    /// The path the input was loaded from, after `pathEnv` and `DOCUCONF_FILE_ROOT`.
    public var resolvedPath: String? { state.value?.path }

    package func store(_ file: LoadedFile, decoders: any StructuredDecoding) throws -> Value {
        let v = Value.wrap(try Value.Base.make(from: file, decoders: decoders))!
        box.value = v
        return v
    }
}

/// A constraint or metadata for a ``FileInput``. Which rules are available depends on the input type.
public struct FileRule<Base>: Sendable {
    let apply: @Sendable (inout FileSpec) -> Void

    public init(_ apply: @escaping @Sendable (inout FileSpec) -> Void) { self.apply = apply }

    /// An environment variable the platform sets to the path, for apps that read the location from the
    /// environment. docuconf reads the path from it when set.
    public static func pathEnv(_ name: String) -> Self { Self { $0.pathEnv = name } }
    /// Long-form documentation in CommonMark (see ``VarRule/details(_:)``).
    public static func details(_ text: String) -> Self { Self { $0.details = text } }
    /// `.watch` promises the app reloads the file itself; consume `$input.changes()` to do so.
    public static func reload(_ r: Reload) -> Self { Self { $0.reload = r } }
    /// Upper bound in bytes.
    public static func maxSize(_ bytes: Int) -> Self { Self { $0.maxSize = bytes } }
    public static func group(_ name: String) -> Self { Self { $0.group = name } }
    public static func deprecated(_ message: String, replacedBy: String? = nil) -> Self {
        Self { $0.deprecated = Deprecation(message: message, replacedBy: replacedBy) }
    }
    /// The content must come from a secret store. Always true for TLS key pairs and keystores.
    public static var secret: Self { Self { $0.secret = true } }
}

extension FileRule {
    public static func format<T>(_ f: ConfigFormat) -> Self where Base == ConfigFile<T> { Self { $0.format = f } }
}

extension FileRule where Base == TLSKeyPair {
    /// Names the certificate must cover. A wildcard certificate (`*.example.com`) covers one label.
    public static func dnsNames(_ names: String...) -> Self { Self { $0.dnsNames = names } }
    public static func keyAlgorithms(_ algorithms: KeyAlgorithm...) -> Self { Self { $0.keyAlgorithms = algorithms } }
    /// The certificate must have at least this long left before it expires.
    public static func minRemaining(_ d: Duration) -> Self { Self { $0.minRemaining = d } }
    /// The directory must hold `ca.crt`, and the certificate must chain to it.
    public static var requireCA: Self { Self { $0.requireCA = true } }
}

extension FileRule where Base == CABundle {
    public static func minCertificates(_ n: Int) -> Self { Self { $0.minCertificates = n } }
}

extension FileRule where Base == Keystore {
    public static func format(_ f: KeystoreFormat) -> Self { Self { $0.keystoreFormat = f } }
    /// The secret variable (environment name) holding the keystore password.
    public static func passwordVar(_ name: String) -> Self { Self { $0.passwordVar = name } }
}

extension FileRule where Base == TextFile {
    public static func pattern(_ p: String) -> Self { Self { $0.pattern = p } }
    public static func length(_ r: ClosedRange<Int>) -> Self { Self { $0.minLength = r.lowerBound; $0.maxLength = r.upperBound } }
    public static func minLength(_ n: Int) -> Self { Self { $0.minLength = n } }
    public static func maxLength(_ n: Int) -> Self { Self { $0.maxLength = n } }
}

extension FileSpec {
    /// Checks a text file's content against its constraints.
    public func checkText(_ text: String) -> [Violation] {
        var out: [Violation] = []
        let n = text.unicodeScalars.count
        let label = secret ? "" : " (\(path))"
        if let minLength, n < minLength { out.append(Violation(.outOfRange, name, "is shorter than \(minLength) characters\(label)")) }
        if let maxLength, n > maxLength { out.append(Violation(.outOfRange, name, "is longer than \(maxLength) characters\(label)")) }
        if let pattern, !RE2.matches(pattern, text) { out.append(Violation(.patternMismatch, name, "does not match \(pattern)\(label)")) }
        return out
    }
}

extension FileInput: CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    /// The loaded value, or `<redacted>` for a secret input (TLS key pairs and keystores are always secret).
    public var description: String { shown(debug: false) }

    public var debugDescription: String { shown(debug: true) }

    /// `dump(config)` shows the same text as `description`, and never the spec, the storage or the bytes.
    public var customMirror: Mirror { Mirror(self, children: [:], displayStyle: nil) }

    private func shown(debug: Bool) -> String {
        guard let v = box.value else { return Redaction.notLoaded }
        if spec.secret { return Redaction.redacted }
        guard let base = v.base else { return "nil" }
        return debug ? String(reflecting: base) : String(describing: base)
    }
}
