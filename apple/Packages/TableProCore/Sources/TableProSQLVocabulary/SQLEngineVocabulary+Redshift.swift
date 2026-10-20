import Foundation

public extension SQLEngineVocabulary {
    // Redshift forked PostgreSQL 8.0 and lacks most of what later releases added, so it keeps a shorter list.
    static let redshift = SQLEngineVocabulary(
        functions: [
            "COUNT", "SUM", "AVG", "MAX", "MIN", "STRING_AGG", "ARRAY_AGG",
            "CONCAT", "SUBSTRING", "LEFT", "RIGHT", "LENGTH", "LOWER", "UPPER",
            "TRIM", "LTRIM", "RTRIM", "REPLACE", "SPLIT_PART",
            "NOW", "CURRENT_DATE", "CURRENT_TIME", "CURRENT_TIMESTAMP",
            "DATE_TRUNC", "EXTRACT", "AGE", "TO_CHAR", "TO_DATE",
            "ROUND", "CEIL", "CEILING", "FLOOR", "ABS", "MOD", "POW", "POWER", "SQRT",
            "CAST", "TO_NUMBER", "TO_TIMESTAMP",
            "JSON_BUILD_OBJECT", "JSON_AGG", "JSONB_BUILD_OBJECT"
        ],
        dataTypes: [
            "INTEGER", "INT", "SMALLINT", "BIGINT", "SERIAL", "BIGSERIAL", "SMALLSERIAL",
            "DECIMAL", "NUMERIC", "REAL", "DOUBLE", "PRECISION",
            "CHAR", "CHARACTER", "VARCHAR", "TEXT",
            "DATE", "TIME", "TIMESTAMP", "TIMESTAMPTZ", "INTERVAL",
            "BOOLEAN", "BOOL", "JSON", "JSONB", "UUID", "BYTEA", "ARRAY"
        ],
        tableOptions: [
            "INHERITS", "PARTITION BY", "TABLESPACE", "WITH", "WITHOUT OIDS"
        ]
    )
}
