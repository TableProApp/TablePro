import Foundation

public enum SQLEscaping {
    public static func ansiStringLiteral(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\0", with: "", options: .literal)
            .replacingOccurrences(of: "'", with: "''", options: .literal)
    }

    public static func backslashStringLiteral(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\", options: .literal)
            .replacingOccurrences(of: "\0", with: "\\0", options: .literal)
            .replacingOccurrences(of: "\n", with: "\\n", options: .literal)
            .replacingOccurrences(of: "\r", with: "\\r", options: .literal)
            .replacingOccurrences(of: "\u{1a}", with: "\\Z", options: .literal)
            .replacingOccurrences(of: "'", with: "''", options: .literal)
    }
}
