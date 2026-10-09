import Configuration
import DocuconfCore
import Foundation

/// Reads variables through swift-configuration and checks them against the declaration.
///
/// A value swift-configuration has as one string (an environment variable) is parsed with the SPEC §5 rules that
/// contract-first mode uses (``VarSpec/parse(wire:)``), so both paths accept exactly the same text; typed values
/// from other providers come through the reader's typed accessors. An empty string is unset for every type but
/// `string`, and the declared constraints are checked.
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
            return e.violations.map { explain($0, spec: spec, raw: raw, options: options) }
        case .success(nil):
            input.storeUnset()
            return []
        case .success(let value?):
            do {
                try input.store(value)
                return []
            } catch let e as ValueConversionError {
                // A secret's decoding errors could describe its content; say only what kind of problem it is.
                if spec.secret && e.code == .schemaMismatch { return [Violation(e.code, spec.name, "does not match its schema")] }
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
        // A value given as one string (an environment variable, a .env file) is parsed by docuconf with the
        // rules contract-first mode uses (SPEC §5), not by swift-configuration, which reads more than the spec
        // allows: `yes`/`no`/`1`/`0` as bools, hexadecimal floats. A provider with typed values (a JSON or YAML
        // config file) is read through the reader's typed accessors.
        case .int:
            if let raw { return spec.parse(wire: raw) }
            return reader.int(forKey: key, isSecret: secret).map { .success(.int($0)) }
        case .float:
            if let raw { return spec.parse(wire: raw) }
            guard let d = reader.double(forKey: key, isSecret: secret) else { return nil }
            return d.isFinite ? .success(.double(d)) : invalid("is not a finite number")
        case .bool:
            if let raw { return spec.parse(wire: raw) }
            return reader.bool(forKey: key, isSecret: secret).map { .success(.bool($0)) }
        case .duration:
            // Encoding "seconds": a number of seconds (`90`, `1.5`). Overlays may hold it as a JSON number.
            guard let raw else {
                guard let d = reader.double(forKey: key, isSecret: secret) else { return nil }
                guard d.isFinite, d >= 0, d < 9.2e9 else { return invalid("is not a non-negative number of seconds") }
                return .success(.duration(.milliseconds(Int64((d * 1000).rounded()))))
            }
            let parsed = spec.parse(wire: raw)
            guard case .failure? = parsed else { return parsed }
            // A Go-style duration (`30s`, `1m30s`) is what the contract and docs show; say what to write instead.
            if let d = GoDuration.parse(raw) {
                let x = Double(GoDuration.nanoseconds(d)) / 1e9
                let seconds = x == x.rounded() && abs(x) < 1e15 ? String(Int64(x)) : "\(x)"
                return invalid("is not a number of seconds; durations are read as plain seconds, so write \(secret ? "a number such as 30" : seconds)")
            }
            return invalid("is not a number of seconds, such as 30 or 1.5")
        case .list, .keySet:
            // A list given as one string (an environment variable) is split by docuconf, not by
            // swift-configuration, whose array decoder trims whitespace around each item: SPEC §5 says values,
            // csv items included, are never trimmed (" a" is the item " a", and " 1" is not an integer).
            if let raw { return spec.parse(wire: raw) }
            // A provider with real arrays (a JSON or YAML config file) needs no splitting.
            if spec.items == .int {
                return reader.intArray(forKey: key, isSecret: secret).map { .success(.intList($0)) }
            }
            return reader.stringArray(forKey: key, isSecret: secret).map { .success(.stringList($0)) }
        }
    }

    /// Adds what to do to a violation: the variable's description and a near-miss name when it is missing, and
    /// the value as written when a duration is out of range.
    static func explain(_ v: Violation, spec: VarSpec, raw: String?, options: LoadOptions) -> Violation {
        switch v.code {
        case .missingRequired:
            var message = v.message + " (\(spec.description))"
            if let typo = TypoHint.nearMiss(of: spec.name, in: options.environment.keys) {
                message += "; \(typo) is set, is it a typo?"
            }
            return Violation(v.code, v.input, message)
        case .outOfRange where spec.type == .duration && !spec.secret:
            guard let raw, let at = v.message.range(of: " (got ") else { return v }
            return Violation(v.code, v.input, v.message[..<at.lowerBound] + " (got \(quoted(raw)) seconds)")
        default:
            return v
        }
    }

    static func quoted(_ s: String) -> String {
        "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n") + "\""
    }
}
