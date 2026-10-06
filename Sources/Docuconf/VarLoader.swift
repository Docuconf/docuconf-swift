import Configuration
import DocuconfCore
import Foundation

/// Reads variables through swift-configuration and checks them against the declaration.
///
/// swift-configuration does the parsing (`int`, `double`, `bool`, `stringArray`, `intArray`), so values
/// mean what they mean to any other `ConfigReader` user. docuconf adds what the spec requires on top: an
/// empty string is unset for every type but `string` (SPEC §5), NaN and infinity are rejected, and the
/// declared constraints are checked.
enum VarLoader {
    static func load(_ input: any AnyEnv, reader: ConfigReader, options: LoadOptions, rawSecrets: inout [String: String]) -> [Violation] {
        let spec = input.spec
        let key = ConfigKey(spec.key)
        let raw = reader.string(forKey: key, isSecret: spec.secret)
        if spec.secret, let raw { rawSecrets[spec.name] = raw }

        // An injector (vault-env, `op run`) that did not run leaves its reference in place (SPEC §4.5.1).
        if spec.secret, let raw, let v = InjectorReference.violation(for: spec.name, value: raw) {
            return [v]
        }

        let parsed: Result<ParsedValue, Violation>?
        if raw == "" && spec.type != .string {
            parsed = nil
        } else {
            parsed = read(spec, key: key, raw: raw, reader: reader)
        }

        guard let parsed else {
            if spec.required {
                return [Violation(.missingRequired, spec.name, "is required but not set")]
            }
            input.storeUnset()
            return []
        }

        if let d = spec.deprecated {
            options.warn("\(spec.name) is deprecated: \(d.message)" + (d.replacedBy.map { " Use \($0) instead." } ?? ""))
        }
        if spec.secret, let raw, raw.hasSuffix("\n") {
            options.warn("\(spec.name) ends with a newline. Values are never trimmed; was the Secret created with --from-file?")
        }

        switch parsed {
        case .failure(let v):
            return [v]
        case .success(let value):
            let violations = spec.check(value)
            if !violations.isEmpty { return violations }
            do {
                try input.store(value)
                return []
            } catch let e as ValueConversionError {
                return [Violation(e.code, spec.name, e.message)]
            } catch {
                return [Violation(.invalidType, spec.name, "could not be converted")]
            }
        }
    }

    /// Returns `nil` when the variable is not set.
    static func read(_ spec: VarSpec, key: ConfigKey, raw: String?, reader: ConfigReader) -> Result<ParsedValue, Violation>? {
        let secret = spec.secret
        func invalid(_ what: String) -> Result<ParsedValue, Violation> {
            .failure(Violation(.invalidType, spec.name, what + (secret || raw == nil ? "" : " (got \(quoted(raw!)))")))
        }
        switch spec.type {
        case .string:
            return raw.map { .success(.string($0)) }
        case .url:
            return raw.map { .success(.url($0)) }
        case .enum:
            return raw.map { .success(.enumCase($0)) }
        case .json:
            return raw.map { .success(.json($0)) }
        case .int:
            if let i = reader.int(forKey: key, isSecret: secret) { return .success(.int(i)) }
            return raw == nil ? nil : invalid("is not a base-10 integer")
        case .float:
            if let d = reader.double(forKey: key, isSecret: secret) {
                return d.isFinite ? .success(.double(d)) : invalid("is not a finite number")
            }
            return raw == nil ? nil : invalid("is not a number")
        case .bool:
            if let b = reader.bool(forKey: key, isSecret: secret) { return .success(.bool(b)) }
            return raw == nil ? nil : invalid("is not true or false")
        case .duration:
            // Encoding "seconds": a number of seconds, read as a Double. A JSON overlay holds it as a string
            // ("90", SPEC §4.7), which JSONSnapshot will not convert to a number, so parse that text too.
            if let d = reader.double(forKey: key, isSecret: secret) ?? raw.flatMap(Double.init) {
                guard d.isFinite, d >= 0, d < 9.2e9 else { return invalid("is not a non-negative number of seconds") }
                return .success(.duration(.milliseconds(Int64((d * 1000).rounded()))))
            }
            return raw == nil ? nil : invalid("is not a number of seconds")
        case .list:
            if spec.items == .int {
                if let l = reader.intArray(forKey: key, isSecret: secret) { return .success(.intList(l)) }
                return raw == nil ? nil : invalid("is not a comma-separated list of integers")
            }
            if let l = reader.stringArray(forKey: key, isSecret: secret) { return .success(.stringList(l)) }
            return raw == nil ? nil : invalid("is not a comma-separated list")
        }
    }

    static func quoted(_ s: String) -> String {
        "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n") + "\""
    }
}
