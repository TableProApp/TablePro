using System.Text;
using TablePro.Core.Schema;
using TablePro.Core.Sql;

namespace TablePro.Drivers.ClickHouse;

/// <summary>The ClickHouse statements for each structure change. Pure, so the text is pinned by unit tests.</summary>
internal static class ClickHouseDdl
{
    /// <summary>The engine reports a dictionary as a table; the session marks it with this comment.</summary>
    public const string DictionaryMarker = "Dictionary";

    public static readonly IReadOnlyList<string> CommonDataTypes =
    [
        "String", "UInt64", "Int64", "UInt32", "Int32", "Float64", "Decimal(18, 2)", "DateTime", "DateTime64(3)", "Date",
        "Bool", "UUID", "LowCardinality(String)", "Array(String)", "Map(String, String)", "Int8", "UInt8", "Int16", "UInt16",
        "Float32", "Date32", "IPv4", "IPv6", "JSON", "Enum8('a' = 1, 'b' = 2)", "FixedString(16)",
    ];

    private const string NullablePrefix = "Nullable(";
    private const string LowCardinalityPrefix = "LowCardinality(";

    private static SqlDialect Dialect => ClickHouseDialect.Instance;

    public static IReadOnlyList<string> Build(ObjectName table, SchemaChange change) => change switch
    {
        CreateTable create => [CreateTable(create)],
        AddColumn add => [string.Concat(AlterTable(table), " ADD COLUMN ", ColumnSql(add.Column))],
        DropColumn drop => [string.Concat(AlterTable(table), " DROP COLUMN ", Q(drop.Column))],
        RenameColumn rename => [string.Concat(AlterTable(table), " RENAME COLUMN ", Q(rename.From), " TO ", Q(rename.To))],
        AlterColumn alter => AlterColumn(table, alter.Before, alter.After),
        CreateIndex index => CreateIndex(table, index.Index),
        DropIndex index => [string.Concat(AlterTable(table), " DROP INDEX ", Q(index.Index))],

        // ClickHouse has no foreign keys.
        AddForeignKey or DropForeignKey => [],

        // Both sides name the same database, so this renames in place; a different database would move the table.
        RenameTable rename => [string.Concat("RENAME TABLE ", Dialect.Qualify(table), " TO ", Dialect.Qualify(table with { Name = rename.NewName }))],
        DropObject drop => DropObject(drop.Object) is { } sql ? [sql] : [],
        TruncateTable => ["TRUNCATE TABLE " + Dialect.Qualify(table)],
        _ => [],
    };

    /// <summary>
    /// A MergeTree ordered by the primary key columns, or by nothing when there are none. Nullability lives in the
    /// type, and a sorting key column may not be Nullable, so key columns are never wrapped.
    /// </summary>
    public static string CreateTable(CreateTable change)
    {
        var sql = new StringBuilder("CREATE TABLE ").Append(Dialect.Qualify(change.Table)).Append("\n(\n    ");
        var keys = new List<string>();
        for (var i = 0; i < change.Columns.Count; i++)
        {
            var column = change.Columns[i];
            if (i > 0)
            {
                sql.Append(",\n    ");
            }

            sql.Append(ColumnSql(column));
            if (column.IsPrimaryKey)
            {
                keys.Add(Q(column.Name));
            }
        }

        sql.Append("\n)\nENGINE = MergeTree\nORDER BY ");
        sql.Append(keys.Count switch
        {
            0 => "tuple()",
            1 => keys[0],
            _ => string.Concat("(", string.Join(", ", keys), ")"),
        });
        return sql.ToString();
    }

    public static string ColumnSql(ColumnDefinition column)
    {
        var sql = new StringBuilder(Q(column.Name)).Append(' ').Append(TypeFor(column));
        if (!string.IsNullOrWhiteSpace(column.DefaultExpression))
        {
            sql.Append(" DEFAULT ").Append(column.DefaultExpression.Trim());
        }

        if (!string.IsNullOrEmpty(column.Comment))
        {
            sql.Append(" COMMENT ").Append(Dialect.StringLiteral(column.Comment));
        }

        return sql.ToString();
    }

    /// <summary>The column's type with <c>Nullable</c> added or taken away to match its nullability.</summary>
    public static string TypeFor(ColumnDefinition column)
    {
        var type = column.DataType.Trim();
        var nullable = column.IsNullable && !column.IsPrimaryKey;
        if (TryUnwrap(type, LowCardinalityPrefix, out var inner))
        {
            return string.Concat(LowCardinalityPrefix, ApplyNullable(inner, nullable), ")");
        }

        return ApplyNullable(type, nullable);
    }

    public static bool IsNullableType(string type)
    {
        var trimmed = type.Trim();
        if (TryUnwrap(trimmed, LowCardinalityPrefix, out var inner))
        {
            trimmed = inner;
        }

        return trimmed.StartsWith(NullablePrefix, StringComparison.Ordinal);
    }

    /// <summary>
    /// A changed type, nullability or default restates the column with MODIFY COLUMN. Making a column non-nullable
    /// needs a DEFAULT to fill its NULLs (the server refuses the change without one from 25.12), so when the draft has
    /// none the type's own default is used and taken away again after.
    /// </summary>
    public static List<string> AlterColumn(ObjectName table, ColumnDefinition before, ColumnDefinition after)
    {
        var statements = new List<string>(4);
        var name = Q(before.Name);
        var beforeType = TypeFor(before);
        var afterType = TypeFor(after);
        var typeChanged = !string.Equals(beforeType, afterType, StringComparison.Ordinal);
        var beforeDefault = before.DefaultExpression?.Trim();
        var afterDefault = string.IsNullOrWhiteSpace(after.DefaultExpression) ? null : after.DefaultExpression.Trim();
        var defaultChanged = !string.Equals(beforeDefault ?? string.Empty, afterDefault ?? string.Empty, StringComparison.Ordinal);

        if (typeChanged || (defaultChanged && afterDefault is not null))
        {
            var losesNull = IsNullableType(beforeType) && !IsNullableType(afterType);
            var sql = new StringBuilder(AlterTable(table)).Append(" MODIFY COLUMN ").Append(name).Append(' ').Append(afterType);
            if (afterDefault is not null)
            {
                sql.Append(" DEFAULT ").Append(afterDefault);
                statements.Add(sql.ToString());
            }
            else if (losesNull)
            {
                sql.Append(" DEFAULT defaultValueOfTypeName(").Append(Dialect.StringLiteral(afterType)).Append(')');
                statements.Add(sql.ToString());
                statements.Add(string.Concat(AlterTable(table), " MODIFY COLUMN ", name, " REMOVE DEFAULT"));
            }
            else
            {
                statements.Add(sql.ToString());
            }
        }

        if (defaultChanged && afterDefault is null && beforeDefault is { Length: > 0 }
            && !statements.Exists(s => s.EndsWith(" REMOVE DEFAULT", StringComparison.Ordinal)))
        {
            statements.Add(string.Concat(AlterTable(table), " MODIFY COLUMN ", name, " REMOVE DEFAULT"));
        }

        if (!string.Equals(before.Comment ?? string.Empty, after.Comment ?? string.Empty, StringComparison.Ordinal))
        {
            statements.Add(string.Concat(AlterTable(table), " COMMENT COLUMN ", name, " ", Dialect.StringLiteral(after.Comment ?? string.Empty)));
        }

        if (!string.Equals(before.Name, after.Name, StringComparison.Ordinal))
        {
            statements.Add(string.Concat(AlterTable(table), " RENAME COLUMN ", name, " TO ", Q(after.Name)));
        }

        return statements;
    }

    /// <summary>
    /// ClickHouse's secondary indexes are data skipping indexes and none is unique. A minmax index is the general
    /// choice; MATERIALIZE builds it for the parts already written, since ADD INDEX only covers new inserts.
    /// </summary>
    public static List<string> CreateIndex(ObjectName table, IndexDefinition index)
    {
        var expression = index.Columns.Count == 1 ? Q(index.Columns[0]) : string.Concat("(", string.Join(", ", index.Columns.Select(Q)), ")");
        return
        [
            string.Concat(AlterTable(table), " ADD INDEX ", Q(index.Name), " ", expression, " TYPE minmax GRANULARITY 1"),
            string.Concat(AlterTable(table), " MATERIALIZE INDEX ", Q(index.Name)),
        ];
    }

    public static string? DropObject(DatabaseObject obj)
    {
        var keyword = obj.Kind switch
        {
            ObjectKind.Table when obj.Comment == DictionaryMarker => "DICTIONARY",
            ObjectKind.Table => "TABLE",
            ObjectKind.View or ObjectKind.MaterializedView => "VIEW",
            _ => null,
        };

        return keyword is null ? null : string.Concat("DROP ", keyword, " ", Dialect.Qualify(obj.Name));
    }

    public static string ShowCreate(DatabaseObject obj) =>
        string.Concat(obj.Comment == DictionaryMarker ? "SHOW CREATE DICTIONARY " : "SHOW CREATE TABLE ", Dialect.Qualify(obj.Name));

    public static string CreateDatabase(string name) => "CREATE DATABASE " + Q(name);

    public static string DropDatabase(string name) => "DROP DATABASE " + Q(name);

    private static string ApplyNullable(string type, bool nullable)
    {
        var bare = TryUnwrap(type, NullablePrefix, out var inner) ? inner : type;
        return nullable ? string.Concat(NullablePrefix, bare, ")") : bare;
    }

    private static bool TryUnwrap(string type, string prefix, out string inner)
    {
        if (type.StartsWith(prefix, StringComparison.Ordinal) && type.EndsWith(')'))
        {
            inner = type[prefix.Length..^1].Trim();
            return true;
        }

        inner = type;
        return false;
    }

    private static string AlterTable(ObjectName table) => "ALTER TABLE " + Dialect.Qualify(table);

    private static string Q(string identifier) => Dialect.QuoteIdentifier(identifier);
}
