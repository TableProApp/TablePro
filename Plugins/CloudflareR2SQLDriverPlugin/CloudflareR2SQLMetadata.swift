//
//  CloudflareR2SQLMetadata.swift
//  TablePro
//

import Foundation
import TableProPluginKit

/// The values the plugin declares and the app's pre-install catalog must repeat.
///
/// One file, compiled into the plugin and into the test target, so a parity test can hold the
/// app's curated snapshot to exactly these values instead of two hand-typed copies drifting apart.
enum CloudflareR2SQLMetadata {
    static let displayName = "Cloudflare R2 SQL"
    static let iconName = "cloudflare-r2-sql-icon"
    static let brandColorHex = "#F6821F"
    static let defaultSchemaName = ""
    static let schemaEntityName = "Namespace"
    static let containerEntityName = "Bucket"
    static let maximumRows = 10_000
    static let accountIdFieldId = "r2AccountId"
    static let bucketFieldId = "r2Bucket"

    static let explainVariants: [ExplainVariant] = [
        ExplainVariant(id: "explain", label: "Explain", sqlPrefix: "EXPLAIN"),
        ExplainVariant(id: "explainJson", label: "Explain (JSON)", sqlPrefix: "EXPLAIN FORMAT JSON")
    ]

    static let structureColumnFields: [StructureColumnField] = [.name, .type, .nullable, .comment]

    static let columnTypesByCategory: [String: [String]] = [
        "Integer": ["TINYINT", "SMALLINT", "INT", "BIGINT"],
        "Float": ["REAL", "DOUBLE", "DECIMAL"],
        "String": ["TEXT"],
        "Date": ["DATE", "TIME", "TIMESTAMP", "TIMESTAMPTZ"],
        "Binary": ["BINARY"],
        "Boolean": ["BOOLEAN"],
        "Nested": ["ARRAY", "STRUCT", "MAP"]
    ]

    static let statementCompletions: [CompletionEntry] = [
        CompletionEntry(label: "SELECT", insertText: "SELECT * FROM namespace.table LIMIT 100"),
        CompletionEntry(label: "SHOW NAMESPACES", insertText: "SHOW NAMESPACES"),
        CompletionEntry(label: "SHOW TABLES", insertText: "SHOW TABLES IN namespace"),
        CompletionEntry(label: "DESCRIBE", insertText: "DESCRIBE namespace.table"),
        CompletionEntry(label: "EXPLAIN", insertText: "EXPLAIN SELECT * FROM namespace.table LIMIT 10")
    ]

    static let dialect = SQLDialectDescriptor(
        identifierQuote: "\"",
        keywords: [
            "SELECT", "DISTINCT", "FROM", "WHERE", "GROUP", "BY", "HAVING", "QUALIFY",
            "ORDER", "ASC", "DESC", "NULLS", "FIRST", "LAST", "LIMIT", "AS", "ON", "USING",
            "JOIN", "INNER", "LEFT", "RIGHT", "FULL", "OUTER", "CROSS",
            "AND", "OR", "NOT", "IN", "EXISTS", "LIKE", "ILIKE", "ESCAPE", "BETWEEN", "IS", "NULL",
            "CASE", "WHEN", "THEN", "ELSE", "END",
            "WITH", "UNION", "INTERSECT", "EXCEPT", "ALL",
            "OVER", "PARTITION", "ROWS", "RANGE", "PRECEDING", "FOLLOWING", "CURRENT", "ROW", "UNBOUNDED",
            "SHOW", "NAMESPACES", "DATABASES", "SCHEMAS", "TABLES", "DESCRIBE", "EXPLAIN", "FORMAT", "JSON",
            "TRUE", "FALSE", "CAST"
        ],
        functions: [
            "COUNT", "SUM", "AVG", "MIN", "MAX", "MEDIAN",
            "APPROX_DISTINCT", "APPROX_PERCENTILE_CONT", "APPROX_TOP_K", "PERCENTILE_CONT",
            "ROW_NUMBER", "RANK", "DENSE_RANK", "PERCENT_RANK", "CUME_DIST", "NTILE",
            "LAG", "LEAD", "FIRST_VALUE", "LAST_VALUE", "NTH_VALUE",
            "ABS", "CEIL", "FLOOR", "ROUND", "POWER", "SQRT", "LN", "LOG", "EXP",
            "LENGTH", "LOWER", "UPPER", "TRIM", "LTRIM", "RTRIM", "SUBSTR", "SUBSTRING",
            "REPLACE", "CONCAT", "SPLIT_PART", "STARTS_WITH", "ENDS_WITH", "REGEXP_LIKE",
            "DATE_TRUNC", "DATE_PART", "EXTRACT", "TO_TIMESTAMP", "NOW",
            "COALESCE", "NULLIF", "GET_FIELD", "ARRAY_LENGTH", "MAP_KEYS", "MAP_VALUES", "MAP_EXTRACT"
        ],
        dataTypes: [
            "BOOLEAN", "TINYINT", "SMALLINT", "INT", "BIGINT", "REAL", "DOUBLE", "DECIMAL",
            "TEXT", "DATE", "TIME", "TIMESTAMP", "TIMESTAMPTZ", "BINARY", "ARRAY", "STRUCT", "MAP"
        ],
        regexSyntax: .regexpLike,
        booleanLiteralStyle: .truefalse,
        likeEscapeStyle: .explicit,
        paginationStyle: .limit
    )

    static var connectionFields: [ConnectionField] {
        [
            ConnectionField(
                id: accountIdFieldId,
                label: String(localized: "Account ID"),
                placeholder: "Cloudflare Account ID",
                required: true,
                section: .authentication
            ),
            ConnectionField(
                id: bucketFieldId,
                label: String(localized: "Bucket"),
                placeholder: "my-bucket",
                required: true,
                section: .authentication
            )
        ]
    }
}
