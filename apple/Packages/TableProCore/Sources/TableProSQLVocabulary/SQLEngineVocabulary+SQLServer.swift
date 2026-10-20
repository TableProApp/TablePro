import Foundation

public extension SQLEngineVocabulary {
    static let sqlServer = SQLEngineVocabulary(
        functions: [
            "COUNT", "SUM", "AVG", "MAX", "MIN", "STRING_AGG",
            "CONCAT", "SUBSTRING", "LEFT", "RIGHT", "LEN", "LOWER", "UPPER",
            "TRIM", "LTRIM", "RTRIM", "REPLACE", "CHARINDEX", "PATINDEX",
            "STUFF", "FORMAT",
            "GETDATE", "GETUTCDATE", "SYSDATETIME", "CURRENT_TIMESTAMP",
            "DATEADD", "DATEDIFF", "DATENAME", "DATEPART",
            "CONVERT", "CAST",
            "ROUND", "CEILING", "FLOOR", "ABS", "POWER", "SQRT", "RAND",
            "ISNULL", "ISNUMERIC", "ISDATE", "COALESCE", "NEWID",
            "OBJECT_ID", "OBJECT_NAME", "SCHEMA_NAME", "DB_NAME",
            "SCOPE_IDENTITY", "@@IDENTITY", "@@ROWCOUNT"
        ],
        dataTypes: [
            "INT", "INTEGER", "TINYINT", "SMALLINT", "BIGINT",
            "DECIMAL", "NUMERIC", "FLOAT", "REAL", "MONEY", "SMALLMONEY",
            "CHAR", "VARCHAR", "NCHAR", "NVARCHAR", "TEXT", "NTEXT",
            "BINARY", "VARBINARY", "IMAGE",
            "DATE", "TIME", "DATETIME", "DATETIME2", "SMALLDATETIME", "DATETIMEOFFSET",
            "BIT", "UNIQUEIDENTIFIER", "XML", "SQL_VARIANT",
            "ROWVERSION", "TIMESTAMP", "HIERARCHYID"
        ],
        tableOptions: [
            "ON", "CLUSTERED", "NONCLUSTERED", "WITH", "TEXTIMAGE_ON"
        ]
    )
}
