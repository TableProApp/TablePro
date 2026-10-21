import Foundation

public extension SQLEngineVocabulary {
    static let mySQL = SQLEngineVocabulary(
        functions: [
            "COUNT", "SUM", "AVG", "MAX", "MIN", "GROUP_CONCAT",
            "CONCAT", "SUBSTRING", "LEFT", "RIGHT", "LENGTH", "LOWER", "UPPER",
            "TRIM", "LTRIM", "RTRIM", "REPLACE",
            "NOW", "CURDATE", "CURTIME", "DATE", "TIME", "YEAR", "MONTH", "DAY",
            "DATE_ADD", "DATE_SUB", "DATEDIFF", "TIMESTAMPDIFF",
            "ROUND", "CEIL", "FLOOR", "ABS", "MOD", "POW", "SQRT",
            "CAST", "CONVERT"
        ],
        dataTypes: [
            "INT", "INTEGER", "TINYINT", "SMALLINT", "MEDIUMINT", "BIGINT",
            "DECIMAL", "NUMERIC", "FLOAT", "DOUBLE", "REAL",
            "CHAR", "VARCHAR", "TEXT", "TINYTEXT", "MEDIUMTEXT", "LONGTEXT",
            "BLOB", "TINYBLOB", "MEDIUMBLOB", "LONGBLOB",
            "DATE", "TIME", "DATETIME", "TIMESTAMP", "YEAR",
            "ENUM", "SET", "JSON", "BOOL", "BOOLEAN"
        ],
        tableOptions: [
            "ENGINE=InnoDB", "DEFAULT CHARSET=utf8mb4", "COLLATE=utf8mb4_unicode_ci",
            "AUTO_INCREMENT=", "COMMENT=", "ROW_FORMAT="
        ]
    )
}
