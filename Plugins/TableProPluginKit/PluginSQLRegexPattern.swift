import Foundation

public enum PluginSQLRegexPattern {
    public enum Anchoring: String, Sendable {
        case unanchored
        case prefix
        case suffix
        case exact
    }

    public static func escapedLiteral(_ value: String) -> String {
        var escaped = ""
        escaped.reserveCapacity(value.utf8.count * 2)
        for character in value {
            if metacharacters.contains(character) { escaped.append("\\") }
            escaped.append(character)
        }
        return escaped
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

    private static let metacharacters: Set<Character> = [
        "\\", ".", "*", "+", "?", "(", ")", "[", "]", "{", "}", "|", "^", "$"
    ]
}
