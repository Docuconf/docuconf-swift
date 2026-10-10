import Foundation

/// Stable error codes (SPEC §11.2 item 5).
public enum ViolationCode: String, Sendable, CaseIterable, Codable {
    case missingRequired = "missing_required"
    case invalidType = "invalid_type"
    case outOfRange = "out_of_range"
    case patternMismatch = "pattern_mismatch"
    case notInEnum = "not_in_enum"
    case invalidScheme = "invalid_scheme"
    case tooFewItems = "too_few_items"
    case tooManyItems = "too_many_items"
    case fileMissing = "file_missing"
    case fileUnreadable = "file_unreadable"
    case fileTooLarge = "file_too_large"
    case fileMalformed = "file_malformed"
    case schemaMismatch = "schema_mismatch"
    case certificateInvalid = "certificate_invalid"
    case certificateExpiring = "certificate_expiring"
    case certificateNameMismatch = "certificate_name_mismatch"
    case keyMismatch = "key_mismatch"
    case keystoreUnreadable = "keystore_unreadable"
}

/// One configuration problem found at boot. The message never contains a secret value.
public struct Violation: Error, Sendable, Hashable, CustomStringConvertible {
    public var code: ViolationCode
    /// The environment variable or file input name.
    public var input: String
    public var message: String

    public init(_ code: ViolationCode, _ input: String, _ message: String) {
        self.code = code
        self.input = input
        self.message = message
    }

    public var description: String { "\(input) [\(code.rawValue)]: \(message)" }
}

/// Thrown at boot when the environment or the mounted files violate the declaration.
/// Lists every problem, not just the first.
public struct ConfigurationError: Error, Sendable, CustomStringConvertible {
    public var violations: [Violation]

    public init(violations: [Violation]) {
        self.violations = violations
    }

    public var description: String {
        let n = violations.count
        return "docuconf: \(n) configuration problem\(n == 1 ? "" : "s"):\n"
            + violations.map { "  - \($0)" }.joined(separator: "\n")
    }
}

/// Thrown when the declaration itself is invalid: a bad name, a short description, a default that breaks
/// its own constraints, a non-RE2 pattern. This is a programming error, found before any value is read.
public struct DeclarationError: Error, Sendable, CustomStringConvertible {
    public var problems: [String]

    public init(problems: [String]) {
        self.problems = problems
    }

    public var description: String {
        "docuconf: invalid declaration:\n" + problems.map { "  - \($0)" }.joined(separator: "\n")
    }
}
