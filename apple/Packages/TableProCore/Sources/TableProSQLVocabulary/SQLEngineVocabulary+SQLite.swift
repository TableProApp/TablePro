import Foundation

public extension SQLEngineVocabulary {
    static let sqlite = SQLEngineVocabulary(
        functions: [
            "COUNT", "SUM", "AVG", "MAX", "MIN", "GROUP_CONCAT", "TOTAL",
            "LENGTH", "SUBSTR", "SUBSTRING", "LOWER", "UPPER", "TRIM", "LTRIM", "RTRIM",
            "REPLACE", "INSTR", "PRINTF",
            "DATE", "TIME", "DATETIME", "JULIANDAY", "STRFTIME",
            "ABS", "ROUND", "RANDOM",
            "CAST", "TYPEOF",
            "COALESCE", "IFNULL", "NULLIF", "HEX", "QUOTE"
        ],
        dataTypes: [
            "INTEGER", "REAL", "TEXT", "BLOB", "NUMERIC",
            "INT", "TINYINT", "SMALLINT", "MEDIUMINT", "BIGINT",
            "UNSIGNED", "BIG", "INT2", "INT8",
            "CHARACTER", "VARCHAR", "VARYING", "NCHAR", "NATIVE",
            "NVARCHAR", "CLOB",
            "DOUBLE", "PRECISION", "FLOAT",
            "DECIMAL", "BOOLEAN", "DATE", "DATETIME"
        ],
        tableOptions: [
            "WITHOUT ROWID", "STRICT"
        ]
    )
}
