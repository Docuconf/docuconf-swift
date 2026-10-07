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

        // The steps contract-first mode shares: an injector reference left in a secret (SPEC §4.5.1), required
        // and unset, then the declared constraints. An empty string is unset for every type but `string`.
        let outcome = spec.resolve(raw: raw) {
            if raw == "" && spec.type != .string { return nil }
            guard let parsed = read(spec, key: key, raw: raw, reader: reader) else { return nil }
            if let d = spec.deprecated {
                options.warn("\(spec.name) is deprecated: \(d.message)" + (d.replacedBy.map { " Use \($0) instead." } ?? ""))
            }
            if spec.secret, let raw, raw.hasSuffix("\n") {
                options.warn("\(spec.name) ends with a newline. Values are never trimmed; was the Secret created with --from-file?")
            }
            return parsed
        }
        switch outcome {
        case .failure(let e):
            return e.violations
        case .success(nil):
            input.storeUnset()
            return []
        case .success(let value?):
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
            guard let raw else { return nil }
            // An integer beyond 64 bits is out_of_range, not invalid_type (SPEC §5).
            if case .failure(.outOfRange) = VarSpec.parseInt(raw) { return .failure(spec.intViolation(.outOfRange, raw)) }
            return invalid("is not a base-10 integer")
        case .float:
            if let d = reader.double(forKey: key, isSecret: secret) {
                return d.isFinite ? .success(.double(d)) : invalid("is not a finite number")
            }
            return raw == nil ? nil : invalid("is not a number")
        case .bool:
            if let b = reader.bool(forKey: key, isSecret: secret) { return .success(.bool(b)) }
            return raw == nil ? nil : invalid("is not true or false")
        case .duration:
            // Encoding "seconds": a number of seconds, read as a Double. Overlays hold it as a number (90, 1.5);
            // a string of seconds ("90", as earlier renderers wrote) is parsed too, since JSONSnapshot will not
            // convert a string to a number.
            if let d = reader.double(forKey: key, isSecret: secret) ?? raw.flatMap(Double.init) {
                guard d.isFinite, d >= 0, d < 9.2e9 else { return invalid("is not a non-negative number of seconds") }
                return .success(.duration(.milliseconds(Int64((d * 1000).rounded()))))
            }
            return raw == nil ? nil : invalid("is not a number of seconds")
        case .list:
            if spec.items == .int {
                if let l = reader.intArray(forKey: key, isSecret: secret) { return .success(.intList(l)) }
                guard let raw else { return nil }
                // Integers that only fail for being beyond 64 bits are out_of_range (SPEC §5).
                let items = raw.split(separator: ",", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
                if case .failure(let v) = spec.parseItems(items, raw: raw), v.code == .outOfRange { return .failure(v) }
                return invalid("is not a comma-separated list of integers")
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
