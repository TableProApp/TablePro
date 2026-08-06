import Foundation

public enum R2SQLLiteral {
    public static func quoteIdentifier(_ identifier: String) -> String {
        "\"" + identifier.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    public static func quoteQualifiedName(_ name: String) -> String {
        name
            .split(separator: ".", omittingEmptySubsequences: false)
            .map { quoteIdentifier(String($0)) }
            .joined(separator: ".")
    }

    public static func escapeStringLiteral(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\u{0}", with: "")
            .replacingOccurrences(of: "'", with: "''")
    }

    public static func stringLiteral(_ value: String) -> String {
        "'" + escapeStringLiteral(value) + "'"
    }

    public static func qualifiedName(namespace: String, table: String) -> String {
        guard !namespace.isEmpty else { return quoteIdentifier(table) }
        return quoteQualifiedName(namespace) + "." + quoteIdentifier(table)
    }
}
