using System.Collections.Frozen;

namespace TablePro.Core.Sql;

/// <summary>The words the editor colors as keywords and offers in completion.</summary>
public static class SqlKeywords
{
    public static readonly FrozenSet<string> All = FrozenSet.Create(
        StringComparer.OrdinalIgnoreCase,
        [
            "ADD", "ALL", "ALTER", "ANALYZE", "AND", "ANY", "AS", "ASC", "ATTACH", "AUTOINCREMENT", "AUTO_INCREMENT",
            "BEGIN", "BETWEEN", "BIGINT", "BINARY", "BLOB", "BOOLEAN", "BOTH", "BY", "CASCADE", "CASE", "CAST", "CHAR",
            "CHECK", "COLLATE", "COLUMN", "COMMENT", "COMMIT", "CONFLICT", "CONSTRAINT", "COPY", "CREATE", "CROSS",
            "CURRENT_DATE", "CURRENT_TIME", "CURRENT_TIMESTAMP", "DATABASE", "DATE", "DATETIME", "DECIMAL", "DECLARE",
            "DEFAULT", "DEFERRABLE", "DELETE", "DESC", "DESCRIBE", "DETACH", "DISTINCT", "DO", "DOUBLE", "DROP", "EACH",
            "ELSE", "END", "ENUM", "ESCAPE", "EXCEPT", "EXEC", "EXECUTE", "EXISTS", "EXPLAIN", "EXTENSION", "FALSE",
            "FETCH", "FILTER", "FIRST", "FLOAT", "FOLLOWING", "FOR", "FOREIGN", "FROM", "FULL", "FUNCTION", "GENERATED",
            "GLOB", "GO", "GRANT", "GROUP", "HAVING", "IDENTITY", "IF", "IGNORE", "ILIKE", "IN", "INDEX", "INNER",
            "INSERT", "INSTEAD", "INT", "INTEGER", "INTERSECT", "INTERVAL", "INTO", "IS", "ISNULL", "JOIN", "JSON",
            "JSONB", "KEY", "LAST", "LATERAL", "LEADING", "LEFT", "LIKE", "LIMIT", "LOCK", "MATERIALIZED", "MERGE",
            "NATURAL", "NOT", "NOTHING", "NOTNULL", "NULL", "NULLS", "NUMERIC", "NVARCHAR", "OF", "OFFSET", "ON",
            "ONLY", "OR", "ORDER", "OUTER", "OVER", "PARTITION", "PRAGMA", "PRECEDING", "PRIMARY", "PROCEDURE", "RANGE",
            "REAL", "RECURSIVE", "REFERENCES", "REGEXP", "RELEASE", "RENAME", "REPLACE", "RESTRICT", "RETURNING",
            "RETURNS", "REVOKE", "RIGHT", "ROLLBACK", "ROW", "ROWS", "SAVEPOINT", "SCHEMA", "SELECT", "SEQUENCE", "SET",
            "SHOW", "SMALLINT", "TABLE", "TEMP", "TEMPORARY", "TEXT", "THEN", "TIES", "TIME", "TIMESTAMP", "TO", "TOP",
            "TRAILING", "TRANSACTION", "TRIGGER", "TRUE", "TRUNCATE", "TYPE", "UNBOUNDED", "UNION", "UNIQUE", "UNSIGNED",
            "UPDATE", "USE", "USING", "UUID", "VACUUM", "VALUES", "VARCHAR", "VIEW", "WHEN", "WHERE", "WINDOW", "WITH",
            "WITHOUT",
        ]);

    public static readonly FrozenSet<string> Functions = FrozenSet.Create(
        StringComparer.OrdinalIgnoreCase,
        [
            "ABS", "AVG", "CEIL", "CEILING", "COALESCE", "CONCAT", "COUNT", "DATE_TRUNC", "DATEADD", "DATEDIFF",
            "DENSE_RANK", "EXTRACT", "FLOOR", "GETDATE", "GREATEST", "GROUP_CONCAT", "IFNULL", "ISNULL", "JSON_EXTRACT",
            "LAG", "LEAD", "LEAST", "LENGTH", "LOWER", "LTRIM", "MAX", "MIN", "NOW", "NTILE", "NULLIF", "RANK", "ROUND",
            "ROW_NUMBER", "RTRIM", "STRING_AGG", "SUBSTR", "SUBSTRING", "SUM", "TO_CHAR", "TO_DATE", "TRIM", "UPPER",
        ]);

    private static readonly FrozenSet<string>.AlternateLookup<ReadOnlySpan<char>> KeywordLookup = All.GetAlternateLookup<ReadOnlySpan<char>>();
    private static readonly FrozenSet<string>.AlternateLookup<ReadOnlySpan<char>> FunctionLookup = Functions.GetAlternateLookup<ReadOnlySpan<char>>();

    public static bool IsKeyword(ReadOnlySpan<char> word) => KeywordLookup.Contains(word);

    public static bool IsFunction(ReadOnlySpan<char> word) => FunctionLookup.Contains(word);
}
