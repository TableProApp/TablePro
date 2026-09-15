import Foundation
import TableProModels
import TableProPluginKit

public protocol SQLDialectProvider: Sendable {
    func dialect(for type: DatabaseType) -> SQLDialectDescriptor?
}

public struct PluginDialectAdapter: SQLDialectProvider, Sendable {
    private let resolveDialect: @Sendable (DatabaseType) -> SQLDialectDescriptor?

    public init(resolveDialect: @escaping @Sendable (DatabaseType) -> SQLDialectDescriptor?) {
        self.resolveDialect = resolveDialect
    }

    public func dialect(for type: DatabaseType) -> SQLDialectDescriptor? {
        resolveDialect(type)
    }
}

public enum SQLDialectFactory {
    public static func defaultDialect() -> SQLDialectDescriptor {
        SQLDialectDescriptor(
            identifierQuote: "\"",
            keywords: ["SELECT", "FROM", "WHERE", "INSERT", "UPDATE", "DELETE", "CREATE", "DROP", "ALTER",
                       "TABLE", "INDEX", "VIEW", "DATABASE", "SCHEMA", "INTO", "VALUES", "SET",
                       "AND", "OR", "NOT", "NULL", "IS", "IN", "LIKE", "BETWEEN", "EXISTS",
                       "JOIN", "LEFT", "RIGHT", "INNER", "OUTER", "ON", "AS", "ORDER", "BY",
                       "GROUP", "HAVING", "LIMIT", "OFFSET", "UNION", "ALL", "DISTINCT",
                       "ASC", "DESC", "BEGIN", "COMMIT", "ROLLBACK", "TRANSACTION"],
            functions: ["COUNT", "SUM", "AVG", "MIN", "MAX", "COALESCE", "IFNULL", "NULLIF",
                        "UPPER", "LOWER", "TRIM", "LENGTH", "SUBSTRING", "CONCAT",
                        "NOW", "CURRENT_TIMESTAMP", "CURRENT_DATE", "CURRENT_TIME",
                        "CAST", "CONVERT", "ABS", "ROUND", "CEIL", "FLOOR"],
            dataTypes: ["INTEGER", "INT", "BIGINT", "SMALLINT", "TINYINT",
                        "VARCHAR", "CHAR", "TEXT", "NVARCHAR",
                        "FLOAT", "DOUBLE", "DECIMAL", "NUMERIC", "REAL",
                        "DATE", "TIME", "DATETIME", "TIMESTAMP",
                        "BOOLEAN", "BOOL",
                        "BLOB", "BINARY", "VARBINARY",
                        "JSON"]
        )
    }
}
