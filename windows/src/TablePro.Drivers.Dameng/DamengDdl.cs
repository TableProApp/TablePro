using System.Globalization;
using System.Text;
using TablePro.Core.Schema;
using TablePro.Core.Sql;
using TablePro.Drivers.Dameng.Localization;
using TablePro.Drivers.Odbc;

namespace TablePro.Drivers.Dameng;

/// <summary>
/// DM8's statements for each structure change, following the macOS driver: Oracle-shaped ALTER TABLE with DM8's
/// <c>IDENTITY(1,1)</c> and a full column definition after MODIFY. Pure, so tests pin them.
/// </summary>
internal static class DamengDdl
{
    public static readonly IReadOnlyList<string> CommonDataTypes =
    [
        "INT", "BIGINT", "SMALLINT", "TINYINT", "NUMBER(18,2)", "DECIMAL(18,2)", "DOUBLE", "REAL", "VARCHAR(255)", "VARCHAR2(255)",
        "VARCHAR(4000)", "CHAR(1)", "TEXT", "CLOB", "DATE", "TIME", "DATETIME", "TIMESTAMP", "BIT", "BOOLEAN", "BLOB", "VARBINARY(255)",
    ];

    private static readonly string[] LengthTypes = ["CHAR", "CHARACTER", "VARCHAR", "VARCHAR2", "BINARY", "VARBINARY"];

    private static readonly string[] NumericTypes = ["DEC", "DECIMAL", "NUMERIC", "NUMBER"];

    private static SqlDialect Dialect => OracleDialect.Instance;

    /// <param name="table">The table, already qualified with the session's schema when the change named none.</param>
    /// <param name="change">The edit.</param>
    /// <param name="backslashEscapes">Whether the server reads a backslash in a literal as an escape, as the connect probe found.</param>
    public static IReadOnlyList<string> Build(ObjectName table, SchemaChange change, bool backslashEscapes = false) => change switch
    {
        CreateTable create => CreateTable(create, backslashEscapes),
        AddColumn add => AddColumn(table, add.Column, backslashEscapes),
        DropColumn drop => [string.Concat(AlterTable(table), " DROP COLUMN ", Q(drop.Column))],
        RenameColumn rename => [RenameColumn(table, rename.From, rename.To)],
        AlterColumn alter => AlterColumn(table, alter.Before, alter.After, backslashEscapes),
        CreateIndex index => [CreateIndex(table, index.Index)],
        DropIndex index => [string.Concat("DROP INDEX ", Qualify(table with { Name = index.Index }))],
        AddForeignKey key => [string.Concat(AlterTable(table), " ADD ", ForeignKey(table, key.ForeignKey))],
        DropForeignKey key => [string.Concat(AlterTable(table), " DROP CONSTRAINT ", Q(key.Name))],

        // Oracle-compatible, so the new name stays bare and the table stays in its schema.
        RenameTable rename => [string.Concat(AlterTable(table), " RENAME TO ", Q(rename.NewName))],
        DropObject drop => DropObject(drop.Object, drop.Cascade) is { } sql ? [sql] : [],

        // DM8 truncates without a CASCADE form.
        TruncateTable => [string.Concat("TRUNCATE TABLE ", Qualify(table))],
        _ => [],
    };

    /// <summary>DEFAULT comes before NOT NULL, the order DM8's grammar takes; an identity takes no default.</summary>
    public static string ColumnSql(ColumnDefinition column, bool inlinePrimaryKey, bool includeIdentity = true)
    {
        var sql = new StringBuilder(Q(column.Name)).Append(' ').Append(column.DataType.Trim());
        if (column.IsIdentity && includeIdentity)
        {
            sql.Append(" IDENTITY(1,1)");
        }
        else if (!string.IsNullOrWhiteSpace(column.DefaultExpression))
        {
            sql.Append(" DEFAULT ").Append(column.DefaultExpression.Trim());
        }

        if (!column.IsNullable && !inlinePrimaryKey)
        {
            sql.Append(" NOT NULL");
        }

        if (inlinePrimaryKey)
        {
            sql.Append(" PRIMARY KEY");
        }

        return sql.ToString();
    }

    public static List<string> CreateTable(CreateTable change, bool backslashEscapes = false)
    {
        var primaryKey = change.Columns.Where(c => c.IsPrimaryKey).Select(c => c.Name).ToList();
        var sql = new StringBuilder("CREATE TABLE ").Append(Qualify(change.Table)).Append(" (\n  ");
        for (var i = 0; i < change.Columns.Count; i++)
        {
            if (i > 0)
            {
                sql.Append(",\n  ");
            }

            var column = change.Columns[i];
            sql.Append(ColumnSql(column, primaryKey.Count == 1 && column.IsPrimaryKey));
        }

        if (primaryKey.Count > 1)
        {
            sql.Append(",\n  PRIMARY KEY (").Append(JoinQuoted(primaryKey)).Append(')');
        }

        var statements = new List<string> { sql.Append("\n)").ToString() };
        foreach (var column in change.Columns)
        {
            if (!string.IsNullOrEmpty(column.Comment))
            {
                statements.Add(ColumnComment(change.Table, column.Name, column.Comment, backslashEscapes));
            }
        }

        return statements;
    }

    public static List<string> AddColumn(ObjectName table, ColumnDefinition column, bool backslashEscapes = false)
    {
        var statements = new List<string>(2) { string.Concat(AlterTable(table), " ADD ", ColumnSql(column, column.IsPrimaryKey)) };
        if (!string.IsNullOrEmpty(column.Comment))
        {
            statements.Add(ColumnComment(table, column.Name, column.Comment, backslashEscapes));
        }

        return statements;
    }

    public static string RenameColumn(ObjectName table, string from, string to) =>
        string.Concat(AlterTable(table), " RENAME COLUMN ", Q(from), " TO ", Q(to));

    /// <summary>
    /// The rename runs first, so MODIFY names the column as it is now called. MODIFY restates the whole definition, as
    /// DM8 takes it, without IDENTITY, which cannot be added or restated there. A removed default is written as
    /// <c>DEFAULT NULL</c> and a column made nullable says <c>NULL</c>, since leaving either out keeps the old value.
    /// </summary>
    public static List<string> AlterColumn(ObjectName table, ColumnDefinition before, ColumnDefinition after, bool backslashEscapes = false)
    {
        var statements = new List<string>(3);
        if (!string.Equals(before.Name, after.Name, StringComparison.Ordinal))
        {
            statements.Add(RenameColumn(table, before.Name, after.Name));
        }

        var typeChanged = !string.Equals(before.DataType.Trim(), after.DataType.Trim(), StringComparison.OrdinalIgnoreCase);
        var nullChanged = before.IsNullable != after.IsNullable;
        var beforeDefault = Trimmed(before.DefaultExpression);
        var afterDefault = Trimmed(after.DefaultExpression);
        var defaultChanged = !string.Equals(beforeDefault, afterDefault, StringComparison.Ordinal);
        if (typeChanged || nullChanged || defaultChanged)
        {
            var sql = new StringBuilder(AlterTable(table)).Append(" MODIFY ").Append(Q(after.Name)).Append(' ').Append(after.DataType.Trim());
            if (afterDefault is not null)
            {
                sql.Append(" DEFAULT ").Append(afterDefault);
            }
            else if (beforeDefault is not null)
            {
                sql.Append(" DEFAULT NULL");
            }

            if (!after.IsNullable)
            {
                sql.Append(" NOT NULL");
            }
            else if (nullChanged)
            {
                sql.Append(" NULL");
            }

            statements.Add(sql.ToString());
        }

        if (!string.Equals(before.Comment ?? string.Empty, after.Comment ?? string.Empty, StringComparison.Ordinal))
        {
            statements.Add(ColumnComment(table, after.Name, after.Comment, backslashEscapes));
        }

        return statements;
    }

    /// <summary>An index lives in its table's schema, which DM8 needs spelled out when the session is elsewhere.</summary>
    public static string CreateIndex(ObjectName table, IndexDefinition index) =>
        string.Concat(
            "CREATE ", index.IsUnique ? "UNIQUE " : string.Empty, "INDEX ", Qualify(table with { Name = index.Name }), " ON ",
            Qualify(table), " (", JoinQuoted(index.Columns), ")");

    /// <summary>The macOS driver writes ON DELETE only, the action DM8 documents; NO ACTION is the default and stays implicit.</summary>
    public static string ForeignKey(ObjectName table, ForeignKeyDefinition key)
    {
        var referenced = key.ReferencedTable.Schema is null ? key.ReferencedTable with { Schema = table.Schema } : key.ReferencedTable;
        var sql = new StringBuilder();
        if (!string.IsNullOrEmpty(key.Name))
        {
            sql.Append("CONSTRAINT ").Append(Q(key.Name)).Append(' ');
        }

        sql.Append("FOREIGN KEY (").Append(JoinQuoted(key.Columns)).Append(") REFERENCES ").Append(Qualify(referenced));
        if (key.ReferencedColumns.Count > 0)
        {
            sql.Append(" (").Append(JoinQuoted(key.ReferencedColumns)).Append(')');
        }

        var onDelete = key.OnDelete?.Trim().ToUpperInvariant();
        if (onDelete is "CASCADE" or "SET NULL" or "SET DEFAULT")
        {
            sql.Append(" ON DELETE ").Append(onDelete);
        }

        return sql.ToString();
    }

    public static string? DropObject(DatabaseObject obj, bool cascade)
    {
        var name = Qualify(obj.Name);
        return obj.Kind switch
        {
            ObjectKind.Table => string.Concat("DROP TABLE ", name, cascade ? " CASCADE" : string.Empty),
            ObjectKind.View => string.Concat("DROP VIEW ", name, cascade ? " CASCADE" : string.Empty),
            ObjectKind.MaterializedView => "DROP MATERIALIZED VIEW " + name,
            ObjectKind.Procedure => "DROP PROCEDURE " + name,
            ObjectKind.Function => "DROP FUNCTION " + name,
            ObjectKind.Sequence => "DROP SEQUENCE " + name,
            ObjectKind.Trigger => "DROP TRIGGER " + name,
            _ => null,
        };
    }

    /// <summary>DM8 takes a string after IS, so the empty string is what removes a comment.</summary>
    public static string ColumnComment(ObjectName table, string column, string? comment, bool backslashEscapes = false) =>
        string.Concat("COMMENT ON COLUMN ", Qualify(table), ".", Q(column), " IS ", StringLiteral(comment ?? string.Empty, backslashEscapes));

    /// <summary>
    /// A literal the server reads back as the same text. NUL ends a DM8 string early, so it is dropped; with the
    /// server's BACKSLASH_ESCAPE on, a backslash is doubled too, or it would escape the character after it.
    /// </summary>
    public static string StringLiteral(string value, bool backslashEscapes)
    {
        var text = value.Replace("\0", string.Empty, StringComparison.Ordinal).Replace("'", "''", StringComparison.Ordinal);
        if (backslashEscapes)
        {
            text = text.Replace("\\", "\\\\", StringComparison.Ordinal);
        }

        return string.Concat("'", text, "'");
    }

    /// <summary>SP_CLOSE_SESSION takes the numeric session id; anything else is refused before it reaches the server.</summary>
    public static long SessionId(object processId) =>
        long.TryParse(Convert.ToString(processId, CultureInfo.InvariantCulture)?.Trim(), NumberStyles.None, CultureInfo.InvariantCulture, out var id)
            ? id
            : throw new ArgumentException(DamengStrings.Format("Dameng/NotASessionId", processId), nameof(processId));

    /// <summary>The type as CREATE TABLE spells it, from ALL_TAB_COLUMNS' parts, as the macOS driver renders it.</summary>
    public static string FormatType(string name, int? length, int? precision, int? scale)
    {
        var type = name.Trim().ToUpperInvariant();
        if (LengthTypes.Contains(type) && length is > 0)
        {
            return string.Create(CultureInfo.InvariantCulture, $"{type}({length})");
        }

        if (NumericTypes.Contains(type) && precision is > 0)
        {
            return scale is > 0
                ? string.Create(CultureInfo.InvariantCulture, $"{type}({precision},{scale})")
                : string.Create(CultureInfo.InvariantCulture, $"{type}({precision})");
        }

        return type == "TIMESTAMP" && scale is > 0 ? string.Create(CultureInfo.InvariantCulture, $"TIMESTAMP({scale})") : type;
    }

    /// <summary>
    /// The table as CREATE TABLE, built from the catalog when SP_TABLEDEF is not available: columns, the primary key
    /// inline, then each other index and comment as its own statement.
    /// </summary>
    public static string TableDefinition(ObjectName table, IReadOnlyList<ColumnInfo> columns, IReadOnlyList<string> indexStatements, bool backslashEscapes)
    {
        var lines = new List<string>(columns.Count + 1);
        foreach (var column in columns)
        {
            var definition = new StringBuilder("  ").Append(Q(column.Name)).Append(' ').Append(column.DataType);
            if (column.IsIdentity)
            {
                definition.Append(" IDENTITY(1,1)");
            }
            else if (column.DefaultValue is not null)
            {
                definition.Append(" DEFAULT ").Append(column.DefaultValue);
            }

            if (!column.IsNullable)
            {
                definition.Append(" NOT NULL");
            }

            lines.Add(definition.ToString());
        }

        var primaryKey = columns.Where(c => c.IsPrimaryKey).Select(c => c.Name).ToList();
        if (primaryKey.Count > 0)
        {
            lines.Add(string.Concat("  PRIMARY KEY (", JoinQuoted(primaryKey), ")"));
        }

        var sql = new StringBuilder("CREATE TABLE ").Append(Qualify(table)).Append(" (\n").AppendJoin(",\n", lines).Append("\n);");
        foreach (var statement in indexStatements)
        {
            sql.Append("\n\n").Append(statement);
        }

        foreach (var column in columns.Where(c => c.Comment is not null))
        {
            sql.Append("\n\n").Append(ColumnComment(table, column.Name, column.Comment, backslashEscapes)).Append(';');
        }

        return sql.ToString();
    }

    /// <summary>One CREATE INDEX per index from rows of INDEX_NAME, UNIQUENESS, COLUMN_NAME, in the order they arrive.</summary>
    public static IReadOnlyList<string> IndexStatements(ObjectName table, IReadOnlyList<object?[]> rows)
    {
        var indexes = DamengCatalog.MapIndexes(rows.Select(r => new[] { r[0], r[1], r[2], null }).ToArray());
        return indexes.Select(i => string.Concat(CreateIndex(table, new IndexDefinition(i.Name, i.Columns, i.IsUnique)), ";")).ToArray();
    }

    /// <summary>CREATE SEQUENCE from ALL_SEQUENCES, starting where the sequence is now so a replay does not reissue values.</summary>
    public static string SequenceDefinition(ObjectName sequence, object?[] row)
    {
        var sql = new StringBuilder("CREATE SEQUENCE ").Append(Qualify(sequence));
        Append(sql, " START WITH ", row[5]);
        Append(sql, " INCREMENT BY ", row[2]);
        Append(sql, " MINVALUE ", row[0]);
        Append(sql, " MAXVALUE ", row[1]);
        sql.Append(string.Equals(CatalogValues.Text(row[3])?.Trim(), "Y", StringComparison.OrdinalIgnoreCase) ? " CYCLE" : " NOCYCLE");
        var cache = CatalogValues.Int64(row[4]);
        sql.Append(cache is > 0 ? string.Create(CultureInfo.InvariantCulture, $" CACHE {cache}") : " NOCACHE");
        return sql.Append(';').ToString();

        static void Append(StringBuilder sql, string clause, object? value)
        {
            if (CatalogValues.Text(value)?.Trim() is { Length: > 0 } text)
            {
                sql.Append(clause).Append(text);
            }
        }
    }

    public static string Qualify(ObjectName name) => Dialect.Qualify(name);

    private static string? Trimmed(string? value) => string.IsNullOrWhiteSpace(value) ? null : value.Trim();

    private static string AlterTable(ObjectName table) => "ALTER TABLE " + Qualify(table);

    private static string Q(string identifier) => Dialect.QuoteIdentifier(identifier);

    private static string JoinQuoted(IReadOnlyList<string> names) => string.Join(", ", names.Select(Q));
}
