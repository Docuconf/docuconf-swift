import Configuration
import DocuconfCore
import Foundation
import Yams
#if TLS
import SwiftASN1
import X509
#endif

/// Decodes JSON with Foundation and YAML with Yams.
public struct DefaultDecoding: StructuredDecoding {
    public init() {}

    public func decode<T: Decodable>(_ type: T.Type, from data: Data, format: ConfigFormat) throws -> T {
        var data = data
        if data.starts(with: [0xEF, 0xBB, 0xBF]) { data = data.dropFirst(3) }
        switch format {
        case .json:
            return try JSONSchema.makeJSONDecoder().decode(type, from: data)
        case .yaml:
            guard let text = String(data: data, encoding: .utf8) else { throw MalformedFileError("not UTF-8") }
            do {
                return try YAMLDecoder().decode(type, from: text)
            } catch let e as YamlError {
                throw MalformedFileError(Self.describe(e))
            }
        case .toml:
            throw MalformedFileError("TOML is not supported")
        }
    }

    /// Yams errors can quote the offending line; keep only the position.
    static func describe(_ e: YamlError) -> String {
        switch e {
        case .scanner(_, let problem, let mark, _), .parser(_, let problem, let mark, _):
            return "\(problem) at line \(mark.line), column \(mark.column)"
        default:
            return "invalid YAML"
        }
    }
}

/// What a file input needs to be loaded again, for `reload: watch`.
struct FileReloadContext: Sendable {
    var options: LoadOptions
    var keystorePassword: String?
}

/// Checks file inputs at boot (SPEC §11.2 item 7).
struct FileLoader: Sendable {
    let options: LoadOptions
    let reader: ConfigReader
    let rawSecrets: [String: String]

    func load(_ input: any AnyFileInput) async -> [Violation] {
        let spec = input.spec
        var path = spec.path
        if let pe = spec.pathEnv, let p = reader.string(forKey: ConfigKey(pe)), !p.isEmpty {
            path = p
        }
        path = options.rooted(path)
        let password = spec.passwordVar.flatMap { rawSecrets[$0] }
        let context = FileReloadContext(options: options, keystorePassword: password)
        input.setState(FileLoadState(path: path, context: context))

        var exists: ObjCBool = false
        let present = FileManager.default.fileExists(atPath: path, isDirectory: &exists)
        if !present || exists.boolValue != (spec.type == .tls) {
            if spec.required {
                let what = spec.type == .tls ? "directory" : "file"
                let reason = present ? "is not a \(what)" : "does not exist"
                return [Violation(.fileMissing, spec.name, "\(path) \(reason)")]
            }
            return []
        }
        if let d = spec.deprecated {
            options.warn("file input \(spec.name) is deprecated: \(d.message)")
        }

        switch await Self.check(spec, at: path, context: context) {
        case .failure(let violations):
            return violations
        case .success(let file):
            do {
                try input.store(file, decoders: options.decoders)
                return []
            } catch let e as ValueConversionError {
                return [Self.violation(e, spec)]
            } catch {
                return [Violation(.fileMalformed, spec.name, "\(path) could not be loaded")]
            }
        }
    }

    static func violation(_ e: ValueConversionError, _ spec: FileSpec) -> Violation {
        // A secret file's parse errors could echo its content; say only what kind of problem it is.
        if spec.secret && (e.code == .fileMalformed || e.code == .schemaMismatch) {
            return Violation(e.code, spec.name, e.code == .fileMalformed ? "is not valid \(spec.format?.rawValue ?? "content")" : "does not match its schema")
        }
        return Violation(e.code, spec.name, e.message)
    }

    /// Reads and checks one input at `path`. Used at boot and on reload.
    static func check(_ spec: FileSpec, at path: String, context: FileReloadContext) async -> Checked<LoadedFile> {
        let name = spec.name
        if spec.type == .tls {
            return await TLSCheck.check(spec, directory: path, now: context.options.now())
        }

        let data: Data
            #if TLS
        do {
            #else
            return .failure([Violation(.certificateInvalid, name, "TLS key pairs need docuconf's TLS trait")])
            #endif
            if let maxSize = spec.maxSize,
                let size = (try? FileManager.default.attributesOfItem(atPath: path))?[.size] as? NSNumber,
                size.intValue > maxSize
            {
                return .failure([Violation(.fileTooLarge, name, "\(path) is \(size.intValue) bytes, larger than maxSize \(maxSize)")])
            }
            data = try readFile(path)
        } catch let v as Violation {
            return .failure([v.with(input: name)])
        } catch {
            return .failure([Violation(.fileUnreadable, name, "\(path) could not be read")])
        }

        var file = LoadedFile(path: path, data: data, format: spec.format)
        switch spec.type {
        case .config, .binary, .tls:
            break
        case .text:
            guard let text = String(data: data, encoding: .utf8) else {
                return .failure([Violation(.fileMalformed, name, "\(path) is not UTF-8 text")])
            }
            let violations = spec.checkText(text)
            if !violations.isEmpty { return .failure(violations) }
        case .caBundle:
            switch PEM.certificates(in: data) {
            case .failure(let problems):
                return .failure([Violation(.fileMalformed, name, "\(path) \(problems[0].message)")])
        #if TLS
            case .success(let certs):
                let min = spec.minCertificates ?? 1
                if certs.count < min {
                    return .failure([Violation(.fileMalformed, name, "\(path) holds \(certs.count) certificate\(certs.count == 1 ? "" : "s"); at least \(min) required")])
                }
                file.certificateCount = certs.count
            }
        case .keystore:
            let format = spec.keystoreFormat ?? .pkcs12
            if let problem = KeystoreCheck.problem(data, format: format, password: context.keystorePassword ?? "") {
                let with = spec.passwordVar.map { "the password in \($0)" } ?? "an empty password"
                return .failure([Violation(.keystoreUnreadable, name, "\(path) is not a \(format.rawValue) keystore that opens with \(with): \(problem)")])
            }
        }
        return .success(file)
    }

        #else
        case .caBundle, .keystore:
            // Unreachable: `Docuconf.load` rejects these declarations without the TLS trait.
            return .failure([Violation(.fileMalformed, name, "\(spec.type.rawValue) inputs need docuconf's TLS trait")])
        #endif
    /// Reads a file, mapping permission problems to `file_unreadable` with the Kubernetes hint.
    static func readFile(_ path: String) throws -> Data {
        guard FileManager.default.isReadableFile(atPath: path) else {
            throw Violation(.fileUnreadable, "", "\(path) is not readable by this process. Secret volumes are owned by root with mode 0400; a non-root container needs the pod's fsGroup set.")
        }
        do {
            return try Data(contentsOf: URL(fileURLWithPath: path))
        } catch {
            throw Violation(.fileUnreadable, "", "\(path) could not be read")
        }
    }
}

/// The outcome of a check: a value, or every violation found.
enum Checked<T> {
    case success(T)
    case failure([Violation])
}

extension Violation {
    func with(input: String) -> Violation { Violation(code, input, message) }
}

/// PEM helpers on swift-certificates.
enum PEM {
    /// Every certificate in a PEM file. Fails if the file has no PEM blocks or a certificate does not parse.
    static func certificates(in data: Data) -> Checked<[Certificate]> {
#if TLS
        guard let text = String(data: data, encoding: .utf8) else { return .failure([Violation(.fileMalformed, "", "is not PEM text")]) }
        let documents: [PEMDocument]
        do {
            documents = try PEMDocument.parseMultiple(pemString: text)
        } catch {
            return .failure([Violation(.fileMalformed, "", "is not valid PEM")])
        }
        var certs: [Certificate] = []
        for (i, doc) in documents.enumerated() where doc.discriminator == "CERTIFICATE" {
            do {
                certs.append(try Certificate(derEncoded: doc.derBytes))
            } catch {
                return .failure([Violation(.fileMalformed, "", "holds a malformed certificate (block \(i + 1))")])
            }
        }
        return .success(certs)
    }
}
#endif
