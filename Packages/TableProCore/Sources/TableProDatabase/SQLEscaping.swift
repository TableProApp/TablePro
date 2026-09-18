import Foundation

public enum SQLEscaping {
    public static func ansiStringLiteral(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\0", with: "")
            .replacingOccurrences(of: "'", with: "''")
    }

    public static func backslashStringLiteral(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\0", with: "\\0")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\r")
            .replacingOccurrences(of: "\u{1a}", with: "\\Z")
            .replacingOccurrences(of: "'", with: "''")
    }
}
