import Foundation

public enum R2SQLIntrospectionSQL {
    public static func showNamespaces() -> String {
        "SHOW NAMESPACES"
    }

    public static func showTables(namespace: String) -> String {
        "SHOW TABLES IN \(R2SQLLiteral.quoteQualifiedName(namespace))"
    }

    public static func describe(namespace: String, table: String) -> String {
        "DESCRIBE \(R2SQLLiteral.qualifiedName(namespace: namespace, table: table))"
    }
}
