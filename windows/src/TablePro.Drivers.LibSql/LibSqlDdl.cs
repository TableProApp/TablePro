using System.Buffers;
using System.Globalization;
using System.Text;
using TablePro.Core.Schema;
using TablePro.Core.Sql;

namespace TablePro.Drivers.LibSql;

/// <summary>
/// The structure edits a remote libSQL database takes: the ones SQLite's ALTER TABLE expresses in one statement.
/// A change that SQLite makes by rebuilding the table (a new type, nullability or default, a foreign key, a check)
/// comes back empty. Over HTTP each statement is its own request, so a rebuild could not hold the transaction and
/// foreign-key switch it needs; the macOS app leaves those to a local file as well. Pure, so tests pin the text.
/// </summary>
internal static class LibSqlDdl
{
    public static readonly IReadOnlyList<string> CommonDataTypes =
        ["INTEGER", "TEXT", "REAL", "BLOB", "NUMERIC", "BOOLEAN", "DATETIME", "DATE", "VARCHAR(255)", "DECIMAL(10,2)"];

    private static readonly SearchValues<char> ExpressionCharacters = SearchValues.Create("()|+-*/%<>=!~& ,");

    private static SqlDialect Dialect => SqliteDialect.Instance;

    public static IReadOnlyList<string> Build(ObjectName table, SchemaChange change) => change switch
    {
        CreateTable create => create.Columns.Count == 0 ? [] : [CreateTable(create)],
        AddColumn add => [string.Concat("ALTER TABLE ", Q(table.Name), " ADD COLUMN ", ColumnSql(add.Column with { IsPrimaryKey = false }, inlinePrimaryKey: false))],
        DropColumn drop => [string.Concat("ALTER TABLE ", Q(table.Name), " DROP COLUMN ", Q(drop.Column))],
        RenameColumn rename => [RenameColumn(table, rename.From, rename.To)],
        AlterColumn alter => AlterColumn(table, alter.Before, alter.After),
        CreateIndex index => [CreateIndex(table, index.Index)],
        DropIndex index => ["DROP INDEX " + Q(index.Index)],
        RenameTable rename => [string.Concat("ALTER TABLE ", Q(table.Name), " RENAME TO ", Q(rename.NewName))],
        DropObject drop => DropObject(drop.Object) is { } sql ? [sql] : [],

        // SQLite has no TRUNCATE; an unqualified DELETE takes its truncate optimization.
        TruncateTable => ["DELETE FROM " + Q(table.Name)],
        _ => [],
    };

    public static string ColumnSql(ColumnDefinition column, bool inlinePrimaryKey)
    {
        var sql = new StringBuilder(Q(column.Name));
        if (!string.IsNullOrWhiteSpace(column.DataType))
        {
            sql.Append(' ').Append(column.DataType.Trim());
        }

        if (inlinePrimaryKey)
        {
            sql.Append(" PRIMARY KEY");

            // AUTOINCREMENT is only legal on the rowid alias, which is exactly an INTEGER primary key.
            if (column.IsIdentity && string.Equals(column.DataType.Trim(), "INTEGER", StringComparison.OrdinalIgnoreCase))
            {
                sql.Append(" AUTOINCREMENT");
            }
        }

        if (!column.IsNullable)
        {
            sql.Append(" NOT NULL");
        }

        if (DefaultValue(column.DefaultExpression) is { } value)
        {
            sql.Append(" DEFAULT ").Append(value);
        }

        return sql.ToString();
    }

    public static string CreateTable(CreateTable change)
    {
        var keys = change.Columns.Where(c => c.IsPrimaryKey).Select(c => c.Name).ToArray();
        var entries = change.Columns.Select(c => ColumnSql(c, keys.Length == 1 && c.IsPrimaryKey)).ToList();
        if (keys.Length > 1)
        {
            entries.Add(string.Concat("PRIMARY KEY (", JoinQuoted(keys), ")"));
        }

        return string.Concat("CREATE TABLE ", Q(change.Table.Name), " (\n  ", string.Join(",\n  ", entries), "\n)");
    }

    public static string RenameColumn(ObjectName table, string from, string to) =>
        string.Concat("ALTER TABLE ", Q(table.Name), " RENAME COLUMN ", Q(from), " TO ", Q(to));

    /// <summary>A rename alone is one statement; anything else would rebuild the table, which remote mode does not do.</summary>
    public static IReadOnlyList<string> AlterColumn(ObjectName table, ColumnDefinition before, ColumnDefinition after)
    {
        var sameDefinition = string.Equals(before.DataType.Trim(), after.DataType.Trim(), StringComparison.OrdinalIgnoreCase)
            && before.IsNullable == after.IsNullable
            && string.Equals(before.DefaultExpression?.Trim() ?? string.Empty, after.DefaultExpression?.Trim() ?? string.Empty, StringComparison.Ordinal);
        if (!sameDefinition)
        {
            return [];
        }

        // SQLite keeps no column comments, so a comment-only edit has nothing to run.
        return string.Equals(before.Name, after.Name, StringComparison.Ordinal) ? [] : [RenameColumn(table, before.Name, after.Name)];
    }

    public static string CreateIndex(ObjectName table, IndexDefinition index) =>
        string.Concat("CREATE ", index.IsUnique ? "UNIQUE " : string.Empty, "INDEX ", Q(index.Name), " ON ", Q(table.Name), " (", JoinQuoted(index.Columns), ")");

    public static string? DropObject(DatabaseObject obj) => obj.Kind switch
    {
        ObjectKind.Table => "DROP TABLE " + Q(obj.Name.Name),
        ObjectKind.View => "DROP VIEW " + Q(obj.Name.Name),
        ObjectKind.Trigger => "DROP TRIGGER " + Q(obj.Name.Name),
        _ => null,
    };

    /// <summary>
    /// A default as <c>PRAGMA table_info</c> reports it, turned back into SQL that recreates it. The pragma drops the
    /// parentheses around an expression and the quotes around a bare word, and the two differ: <c>DEFAULT abc</c>
    /// stores the text <c>abc</c>, while <c>datetime('now')</c> parses only inside parentheses. An expression always
    /// has a call or an operator and a bare word never does, which is what tells them apart.
    /// </summary>
    public static string? DefaultValue(string? value)
    {
        if (string.IsNullOrWhiteSpace(value))
        {
            return null;
        }

        var text = value.Trim();
        var upper = text.ToUpperInvariant();
        if (upper is "NULL" or "TRUE" or "FALSE" or "CURRENT_TIMESTAMP" or "CURRENT_DATE" or "CURRENT_TIME"
            || text.StartsWith('(')
            || upper.StartsWith("X'", StringComparison.Ordinal)
            || (text[0] is (>= '0' and <= '9') or '-' or '+' or '.' && double.TryParse(text, NumberStyles.Float, CultureInfo.InvariantCulture, out _))
            || IsWholeStringLiteral(text))
        {
            return text;
        }

        return text.AsSpan().ContainsAny(ExpressionCharacters) ? string.Concat("(", text, ")") : Dialect.StringLiteral(text);
    }

    /// <summary>One single-quoted literal, rather than an expression that happens to start and end with a quote.</summary>
    private static bool IsWholeStringLiteral(string text)
    {
        if (text.Length < 2 || text[0] != '\'' || text[^1] != '\'')
        {
            return false;
        }

        for (var i = 1; i < text.Length - 1; i++)
        {
            if (text[i] == '\'')
            {
                if (i + 1 >= text.Length - 1 || text[i + 1] != '\'')
                {
                    return false;
                }

                i++;
            }
        }

        return true;
    }

    private static string Q(string identifier) => Dialect.QuoteIdentifier(identifier);

    private static string JoinQuoted(IEnumerable<string> names) => string.Join(", ", names.Select(Q));
}
