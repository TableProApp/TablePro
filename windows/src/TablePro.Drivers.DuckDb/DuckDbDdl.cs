using System.Text;
using TablePro.Core.Schema;
using TablePro.Core.Sql;

namespace TablePro.Drivers.DuckDb;

/// <summary>The DuckDB statements for each structure change. Pure, so the text is pinned by unit tests.</summary>
internal static class DuckDbDdl
{
    public static readonly IReadOnlyList<string> CommonDataTypes =
    [
        "INTEGER", "BIGINT", "VARCHAR", "DOUBLE", "DECIMAL(18,3)", "BOOLEAN", "DATE", "TIMESTAMP", "TIMESTAMPTZ", "UUID", "BLOB", "JSON",
        "SMALLINT", "HUGEINT", "REAL", "TIME", "INTERVAL",
    ];

    private static SqlDialect Dialect => DuckDbDialect.Instance;

    public static string Qualify(ObjectName name) => Dialect.Qualify(name);

    /// <summary>
    /// DuckDB has no SERIAL or identity column, so an auto-increment column takes <c>nextval</c> of a sequence of
    /// its own, created beside the table.
    /// </summary>
    public static ObjectName IdentitySequence(ObjectName table, string column) => new(table.Schema, string.Concat(table.Name, "_", column, "_seq"));

    public static string ColumnSql(ObjectName table, ColumnDefinition column, bool inlinePrimaryKey)
    {
        var sql = new StringBuilder(Dialect.QuoteIdentifier(column.Name)).Append(' ').Append(column.DataType.Trim());
        if (inlinePrimaryKey)
        {
            sql.Append(" PRIMARY KEY");
        }
        else if (!column.IsNullable)
        {
            sql.Append(" NOT NULL");
        }

        if (column.IsIdentity)
        {
            sql.Append(" DEFAULT nextval(").Append(Dialect.StringLiteral(Qualify(IdentitySequence(table, column.Name)))).Append(')');
        }
        else if (!string.IsNullOrWhiteSpace(column.DefaultExpression))
        {
            sql.Append(" DEFAULT ").Append(column.DefaultExpression.Trim());
        }

        return sql.ToString();
    }

    public static List<string> CreateTable(CreateTable change)
    {
        var statements = new List<string>();
        var primaryKey = new List<string>();
        foreach (var column in change.Columns)
        {
            if (column.IsPrimaryKey)
            {
                primaryKey.Add(column.Name);
            }

            if (column.IsIdentity)
            {
                statements.Add(CreateSequence(change.Table, column.Name));
            }
        }

        var sql = new StringBuilder("CREATE TABLE ").Append(Qualify(change.Table)).Append(" (\n  ");
        for (var i = 0; i < change.Columns.Count; i++)
        {
            if (i > 0)
            {
                sql.Append(",\n  ");
            }

            var column = change.Columns[i];
            sql.Append(ColumnSql(change.Table, column, primaryKey.Count == 1 && column.IsPrimaryKey));
        }

        if (primaryKey.Count > 1)
        {
            sql.Append(",\n  PRIMARY KEY (").Append(JoinQuoted(primaryKey)).Append(')');
        }

        statements.Add(sql.Append("\n)").ToString());
        foreach (var column in change.Columns)
        {
            if (!string.IsNullOrEmpty(column.Comment))
            {
                statements.Add(ColumnComment(change.Table, column.Name, column.Comment));
            }
        }

        return statements;
    }

    public static List<string> AddColumn(ObjectName table, ColumnDefinition column)
    {
        var statements = new List<string>(3);
        if (column.IsIdentity)
        {
            statements.Add(CreateSequence(table, column.Name));
        }

        // ADD COLUMN takes no constraints; a key is added with an index instead.
        statements.Add(string.Concat("ALTER TABLE ", Qualify(table), " ADD COLUMN ", ColumnSql(table, column with { IsPrimaryKey = false }, inlinePrimaryKey: false)));
        if (!string.IsNullOrEmpty(column.Comment))
        {
            statements.Add(ColumnComment(table, column.Name, column.Comment));
        }

        return statements;
    }

    public static string DropColumn(ObjectName table, string column) =>
        string.Concat("ALTER TABLE ", Qualify(table), " DROP COLUMN ", Dialect.QuoteIdentifier(column));

    public static string RenameColumn(ObjectName table, string from, string to) =>
        string.Concat("ALTER TABLE ", Qualify(table), " RENAME COLUMN ", Dialect.QuoteIdentifier(from), " TO ", Dialect.QuoteIdentifier(to));

    /// <summary>DuckDB's ALTER TABLE takes one action per statement, so each changed property is its own.</summary>
    public static List<string> AlterColumn(ObjectName table, ColumnDefinition before, ColumnDefinition after)
    {
        var statements = new List<string>(5);
        var prefix = string.Concat("ALTER TABLE ", Qualify(table), " ALTER COLUMN ", Dialect.QuoteIdentifier(before.Name));
        if (!string.Equals(before.DataType.Trim(), after.DataType.Trim(), StringComparison.OrdinalIgnoreCase))
        {
            statements.Add(string.Concat(prefix, " SET DATA TYPE ", after.DataType.Trim()));
        }

        if (before.IsNullable != after.IsNullable)
        {
            statements.Add(prefix + (after.IsNullable ? " DROP NOT NULL" : " SET NOT NULL"));
        }

        if (!string.Equals(before.DefaultExpression?.Trim(), after.DefaultExpression?.Trim(), StringComparison.Ordinal))
        {
            statements.Add(string.IsNullOrWhiteSpace(after.DefaultExpression)
                ? prefix + " DROP DEFAULT"
                : string.Concat(prefix, " SET DEFAULT ", after.DefaultExpression.Trim()));
        }

        if (!string.Equals(before.Comment ?? string.Empty, after.Comment ?? string.Empty, StringComparison.Ordinal))
        {
            statements.Add(ColumnComment(table, before.Name, after.Comment));
        }

        if (!string.Equals(before.Name, after.Name, StringComparison.Ordinal))
        {
            statements.Add(RenameColumn(table, before.Name, after.Name));
        }

        return statements;
    }

    public static string CreateIndex(ObjectName table, IndexDefinition index) =>
        string.Concat(
            "CREATE ", index.IsUnique ? "UNIQUE " : string.Empty, "INDEX ", Dialect.QuoteIdentifier(index.Name),
            " ON ", Qualify(table), " (", JoinQuoted(index.Columns), ")");

    public static string DropIndex(ObjectName table, string index) => "DROP INDEX " + Qualify(new ObjectName(table.Schema, index));

    public static string RenameTable(ObjectName table, string newName) =>
        string.Concat("ALTER TABLE ", Qualify(table), " RENAME TO ", Dialect.QuoteIdentifier(newName));

    public static string? DropObject(DatabaseObject obj, bool cascade)
    {
        var keyword = obj.Kind switch
        {
            ObjectKind.Table => "TABLE",
            ObjectKind.View => "VIEW",
            ObjectKind.Sequence => "SEQUENCE",
            ObjectKind.Function => "MACRO",
            _ => null,
        };

        return keyword is null ? null : string.Concat("DROP ", keyword, " ", Qualify(obj.Name), cascade ? " CASCADE" : string.Empty);
    }

    public static string Truncate(ObjectName table) => "TRUNCATE " + Qualify(table);

    // IS '' stores an empty comment; only IS NULL removes one.
    public static string ColumnComment(ObjectName table, string column, string? comment) =>
        string.Concat(
            "COMMENT ON COLUMN ", Qualify(table), ".", Dialect.QuoteIdentifier(column), " IS ",
            string.IsNullOrEmpty(comment) ? "NULL" : Dialect.StringLiteral(comment));

    public static readonly IReadOnlyList<TableOptionSpec> TableOptionSpecs = [new(TableOptionNames.Comment, TableOptionKind.Text)];

    public static List<string> SetOptions(ObjectName table, IReadOnlyList<TableOptionChange> changes)
    {
        var statements = new List<string>(1);
        foreach (var change in changes)
        {
            if (change.Name == TableOptionNames.Comment)
            {
                statements.Add(string.Concat(
                    "COMMENT ON TABLE ", Qualify(table), " IS ", change.Clears ? "NULL" : Dialect.StringLiteral(change.After!.Trim())));
            }
        }

        return statements;
    }

    /// <summary>DuckDB stores a view as the CREATE VIEW it was made with; OR REPLACE lets the user run it back.</summary>
    public static string ReplaceableView(string sql)
    {
        var trimmed = sql.Trim();
        const string Prefix = "CREATE VIEW";
        return trimmed.StartsWith(Prefix, StringComparison.OrdinalIgnoreCase)
            ? string.Concat("CREATE OR REPLACE VIEW", trimmed.AsSpan(Prefix.Length))
            : trimmed;
    }

    /// <summary>The key list of a stored CREATE INDEX, with plain column names unquoted and expressions kept as written.</summary>
    public static List<string> IndexColumns(string? sql)
    {
        var columns = new List<string>();
        if (string.IsNullOrEmpty(sql))
        {
            return columns;
        }

        var span = sql.AsSpan();
        var lexer = new SqlLexer(span, Dialect.LexerFeatures);
        var sawOn = false;
        var depth = 0;
        var itemStart = -1;
        var itemEnd = -1;
        var itemTokens = 0;
        SqlToken single = default;
        while (lexer.TryRead(out var token))
        {
            if (token.IsTrivia)
            {
                continue;
            }

            if (depth == 0)
            {
                if (token.Kind == SqlTokenKind.Word && token.Slice(span).Equals("ON", StringComparison.OrdinalIgnoreCase))
                {
                    sawOn = true;
                }
                else if (sawOn && token.Kind == SqlTokenKind.OpenParen)
                {
                    depth = 1;
                }

                continue;
            }

            var closesList = token.Kind == SqlTokenKind.CloseParen && depth == 1;
            if (closesList || (token.Kind == SqlTokenKind.Comma && depth == 1))
            {
                if (itemStart >= 0)
                {
                    columns.Add(itemTokens == 1 && single.Kind is SqlTokenKind.Word or SqlTokenKind.QuotedIdentifier
                        ? Unquote(single.Slice(span))
                        : sql[itemStart..itemEnd]);
                }

                if (closesList)
                {
                    break;
                }

                itemStart = -1;
                itemTokens = 0;
                continue;
            }

            if (token.Kind == SqlTokenKind.OpenParen)
            {
                depth++;
            }
            else if (token.Kind == SqlTokenKind.CloseParen)
            {
                depth--;
            }

            if (itemStart < 0)
            {
                itemStart = token.Start;
            }

            itemEnd = token.End;
            single = token;
            itemTokens++;
        }

        return columns;
    }

    private static string CreateSequence(ObjectName table, string column) =>
        "CREATE SEQUENCE IF NOT EXISTS " + Qualify(IdentitySequence(table, column));

    private static string Unquote(ReadOnlySpan<char> token) =>
        token.Length >= 2 && token[0] == '"' ? token[1..^1].ToString().Replace("\"\"", "\"", StringComparison.Ordinal) : token.ToString();

    private static string JoinQuoted(IReadOnlyList<string> names)
    {
        var sql = new StringBuilder();
        for (var i = 0; i < names.Count; i++)
        {
            if (i > 0)
            {
                sql.Append(", ");
            }

            sql.Append(Dialect.QuoteIdentifier(names[i]));
        }

        return sql.ToString();
    }
}
