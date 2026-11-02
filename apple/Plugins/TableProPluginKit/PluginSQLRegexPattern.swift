import Foundation

public enum PluginSQLRegexPattern {
    public enum Anchoring: String, Sendable {
        case unanchored
        case prefix
        case suffix
        case exact
    }

    public static func escapedLiteral(_ value: String) -> String {
        var escaped = String.UnicodeScalarView()
        for scalar in value.unicodeScalars {
            if metacharacters.contains(scalar) { escaped.append("\\") }
            escaped.append(scalar)
        }
        return String(escaped)
    }

    public static func pattern(
        matchingLiteral value: String,
        anchoring: Anchoring,
        ignoresCase: Bool
    ) -> String {
        let literal = escapedLiteral(value)
        let body: String
        switch anchoring {
        case .unanchored:
            body = literal
        case .prefix:
            body = "^\(literal)"
        case .suffix:
            body = "\(literal)$"
        case .exact:
            body = "^\(literal)$"
        }
        return ignoresCase ? "(?i)\(body)" : body
    }

    private static let metacharacters: Set<Unicode.Scalar> = [
        "\\", ".", "*", "+", "?", "(", ")", "[", "]", "{", "}", "|", "^", "$"
    ]
}
