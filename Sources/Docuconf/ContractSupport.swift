import DocuconfCore
import Foundation
import Yams

/// What contract-first mode (``ContractDocument``) needs beyond Foundation: YAML config files and overlays (Yams),
/// and, with the package's `TLS` trait, the `tls`, `caBundle` and `keystore` checks the declaration path runs.
///
/// ```swift
/// let contract = try ContractDocument(json: Data(contentsOf: URL(fileURLWithPath: "contract.json")))
/// let values = try await contract.load(support: DocuconfFileSupport())
/// ```
public struct DocuconfFileSupport: ContractFileSupport {
    /// The clock the certificate checks use.
    public var now: @Sendable () -> Date

    public init(now: @escaping @Sendable () -> Date = { Date() }) {
        self.now = now
    }

    public func parse(_ data: Data, format: ConfigFormat) throws -> JSONValue {
        guard format == .yaml else { return try parseJSONOrTOML(data, format: format) }
        return try Self.parseYAML(data)
    }

    public func check(_ spec: FileSpec, at path: String, password: String) async -> [Violation] {
        #if TLS
        let context = FileReloadContext(options: LoadOptions(environment: [:], now: now, appDirectory: nil), keystorePassword: password)
        switch await FileLoader.check(spec, at: path, context: context) {
        case .success: return []
        case .failure(let violations): return violations
        }
        #else
        return [Violation(.fileUnreadable, spec.name,
            "\(spec.type.rawValue) inputs are checked with swift-certificates and swift-crypto, which docuconf builds only with its TLS trait")]
        #endif
    }

    /// A YAML document as JSON data: mappings as objects, sequences as arrays, and scalars by their resolved tag
    /// (null, bool, int, float, otherwise string). Throws ``MalformedFileError`` with the position only, since the
    /// parser's message can quote the line.
    static func parseYAML(_ data: Data) throws -> JSONValue {
        var data = data
        if data.starts(with: [0xEF, 0xBB, 0xBF]) { data = data.dropFirst(3) }
        guard let text = String(data: data, encoding: .utf8) else { throw MalformedFileError("not UTF-8") }
        let node: Node?
        do {
            node = try Yams.compose(yaml: text)
        } catch let e as YamlError {
            throw MalformedFileError(DefaultDecoding.describe(e))
        }
        guard let node else { return .null }
        return try json(node)
    }

    static func json(_ node: Node) throws -> JSONValue {
        switch node {
        case .scalar(let scalar):
            switch Resolver.default.resolveTag(of: node) {
            case .null: return .null
            case .bool:
                guard let b = Bool.construct(from: scalar) else { throw MalformedFileError("a boolean that does not parse") }
                return .bool(b)
            case .int:
                if let i = Int.construct(from: scalar) { return .int(i) }
                throw MalformedFileError("an integer outside the 64-bit range")
            case .float:
                guard let d = Double.construct(from: scalar), d.isFinite else {
                    throw MalformedFileError("a number JSON cannot hold (infinity or NaN)")
                }
                return .double(d)
            default:
                return .string(scalar.string)
            }
        case .mapping(let mapping):
            var members: [(String, JSONValue)] = []
            for (k, v) in mapping {
                guard case .scalar(let key) = k else { throw MalformedFileError("a mapping key that is not a scalar") }
                if members.contains(where: { $0.0 == key.string }) { throw MalformedFileError("duplicate key \(key.string)") }
                members.append((key.string, try json(v)))
            }
            return .object(members)
        case .sequence(let sequence):
            return .array(try sequence.map(json))
        case .alias:
            throw MalformedFileError("an unresolved alias")
        }
    }
}
