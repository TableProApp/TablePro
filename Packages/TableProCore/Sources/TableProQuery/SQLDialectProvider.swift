import Foundation
import TableProCoreTypes

public protocol SQLDialectProvider: Sendable {
    func dialect(for type: DatabaseType) -> QueryDialectDescriptor?
}

public struct PluginDialectAdapter: SQLDialectProvider, Sendable {
    private let resolveDialect: @Sendable (DatabaseType) -> QueryDialectDescriptor?

    public init(resolveDialect: @escaping @Sendable (DatabaseType) -> QueryDialectDescriptor?) {
        self.resolveDialect = resolveDialect
    }

    public func dialect(for type: DatabaseType) -> QueryDialectDescriptor? {
        resolveDialect(type)
    }
}

public enum SQLDialectFactory {
    private static let commonKeywords: Set<String> = [
        "SELECT", "FROM", "WHERE", "INSERT", "UPDATE", "DELETE", "CREATE", "DROP", "ALTER",
        "TABLE", "INDEX", "VIEW", "DATABASE", "SCHEMA", "INTO", "VALUES", "SET",
        "AND", "OR", "NOT", "NULL", "IS", "IN", "LIKE", "BETWEEN", "EXISTS",
        "JOIN", "LEFT", "RIGHT", "INNER", "OUTER", "ON", "AS", "ORDER", "BY",
        "GROUP", "HAVING", "LIMIT", "OFFSET", "UNION", "ALL", "DISTINCT",
        "ASC", "DESC", "BEGIN", "COMMIT", "ROLLBACK", "TRANSACTION"
    ]

    private static let commonFunctions: Set<String> = [
        "COUNT", "SUM", "AVG", "MIN", "MAX", "COALESCE", "IFNULL", "NULLIF",
        "UPPER", "LOWER", "TRIM", "LENGTH", "SUBSTRING", "CONCAT",
        "NOW", "CURRENT_TIMESTAMP", "CURRENT_DATE", "CURRENT_TIME",
        "CAST", "CONVERT", "ABS", "ROUND", "CEIL", "FLOOR"
    ]

    private static let commonDataTypes: Set<String> = [
        "INTEGER", "INT", "BIGINT", "SMALLINT", "TINYINT",
        "VARCHAR", "CHAR", "TEXT", "NVARCHAR",
        "FLOAT", "DOUBLE", "DECIMAL", "NUMERIC", "REAL",
        "DATE", "TIME", "DATETIME", "TIMESTAMP",
        "BOOLEAN", "BOOL",
        "BLOB", "BINARY", "VARBINARY",
        "JSON"
    ]

    public static func defaultDialect() -> QueryDialectDescriptor {
        QueryDialectDescriptor(
            identifierQuote: "\"",
            keywords: commonKeywords,
            functions: commonFunctions,
            dataTypes: commonDataTypes
        )
    }

    public static func dialect(for type: DatabaseType) -> QueryDialectDescriptor {
        switch type {
        case .mysql, .mariadb:
            return QueryDialectDescriptor(
                identifierQuote: "`",
                keywords: commonKeywords,
                functions: commonFunctions,
                dataTypes: commonDataTypes,
                regexSyntax: .regexp,
                likeEscapeStyle: .implicit,
                requiresBackslashEscaping: true
            )
        case .postgresql, .redshift, .cockroachdb:
            return QueryDialectDescriptor(
                identifierQuote: "\"",
                keywords: commonKeywords,
                functions: commonFunctions,
                dataTypes: commonDataTypes,
                regexSyntax: .tilde,
                booleanLiteralStyle: .truefalse,
                likeEscapeStyle: .explicit
            )
        case .sqlite:
            return QueryDialectDescriptor(
                identifierQuote: "`",
                keywords: commonKeywords,
                functions: commonFunctions,
                dataTypes: commonDataTypes,
                likeEscapeStyle: .explicit
            )
        case .mssql:
            return QueryDialectDescriptor(
                identifierQuote: "[",
                identifierClosingQuote: "]",
                keywords: commonKeywords,
                functions: commonFunctions,
                dataTypes: commonDataTypes,
                likeEscapeStyle: .explicit,
                paginationStyle: .offsetFetch,
                autoLimitStyle: .top
            )
        case .oracle:
            return QueryDialectDescriptor(
                identifierQuote: "\"",
                keywords: commonKeywords,
                functions: commonFunctions,
                dataTypes: commonDataTypes,
                regexSyntax: .regexpLike,
                likeEscapeStyle: .explicit,
                paginationStyle: .offsetFetch,
                autoLimitStyle: .fetchFirst
            )
        case .clickhouse:
            return QueryDialectDescriptor(
                identifierQuote: "`",
                keywords: commonKeywords,
                functions: commonFunctions,
                dataTypes: commonDataTypes,
                regexSyntax: .match,
                likeEscapeStyle: .implicit,
                requiresBackslashEscaping: true
            )
        case .duckdb:
            return QueryDialectDescriptor(
                identifierQuote: "\"",
                keywords: commonKeywords,
                functions: commonFunctions,
                dataTypes: commonDataTypes,
                regexSyntax: .regexpMatches,
                booleanLiteralStyle: .truefalse,
                likeEscapeStyle: .explicit
            )
        case .bigQuery, .bigquery:
            return QueryDialectDescriptor(
                identifierQuote: "`",
                keywords: commonKeywords,
                functions: commonFunctions,
                dataTypes: commonDataTypes,
                booleanLiteralStyle: .truefalse,
                likeEscapeStyle: .explicit
            )
        case .libsql, .cloudflareD1, .turso:
            return QueryDialectDescriptor(
                identifierQuote: "\"",
                keywords: commonKeywords,
                functions: commonFunctions,
                dataTypes: commonDataTypes,
                likeEscapeStyle: .explicit
            )
        default:
            return defaultDialect()
        }
    }

    public static func quoteIdentifier(_ name: String, for type: DatabaseType) -> String {
        dialect(for: type).quoteIdentifier(name)
    }
}
