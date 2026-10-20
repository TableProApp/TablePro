import Foundation

public extension SQLEngineVocabulary {
    static let duckDB = SQLEngineVocabulary(
        functions: [
            "COUNT", "SUM", "AVG", "MAX", "MIN",
            "LIST_AGG", "STRING_AGG", "ARRAY_AGG",
            "CONCAT", "SUBSTRING", "LEFT", "RIGHT", "LENGTH", "LOWER", "UPPER",
            "TRIM", "LTRIM", "RTRIM", "REPLACE", "SPLIT_PART",
            "NOW", "CURRENT_DATE", "CURRENT_TIME", "CURRENT_TIMESTAMP",
            "DATE_TRUNC", "EXTRACT", "AGE", "TO_CHAR", "TO_DATE",
            "EPOCH_MS",
            "ROUND", "CEIL", "CEILING", "FLOOR", "ABS", "MOD", "POW", "POWER", "SQRT",
            "CAST",
            "REGEXP_MATCHES", "READ_CSV", "READ_PARQUET", "READ_JSON",
            "GLOB", "STRUCT_PACK", "LIST_VALUE", "MAP", "UNNEST",
            "GENERATE_SERIES", "RANGE"
        ],
        bareFunctions: ["CURRENT_DATE", "CURRENT_TIME", "CURRENT_TIMESTAMP"],
        dataTypes: [
            "INTEGER", "BIGINT", "HUGEINT", "UHUGEINT",
            "DOUBLE", "FLOAT", "DECIMAL",
            "VARCHAR", "TEXT", "BLOB",
            "BOOLEAN",
            "DATE", "TIME", "TIMESTAMP", "TIMESTAMP WITH TIME ZONE", "INTERVAL",
            "UUID", "JSON",
            "LIST", "MAP", "STRUCT", "UNION", "ENUM", "BIT"
        ]
    )
}
