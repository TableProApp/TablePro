using System.Globalization;
using System.Text;
using TablePro.Core.Schema;

namespace TablePro.Drivers.Snowflake;

/// <summary>
/// The Snowflake statements for each structure change, within Snowflake's documented limits: a VARCHAR only widens,
/// a NUMBER only changes precision at the same scale, and no column changes type family. A change outside them comes
/// back empty, so the app says it cannot be made instead of the server failing half way. Pure, so tests pin the text.
/// </summary>
internal static class SnowflakeDdl
{
    /// <summary>VARCHAR's length when none is written, the most Snowflake stores.</summary>
    private const long MaxTextLength = 16_777_216;

    public static readonly IReadOnlyList<string> CommonDataTypes =
    [
        "NUMBER(38,0)", "VARCHAR", "BOOLEAN", "TIMESTAMP_NTZ", "DATE", "FLOAT", "NUMBER(18,2)", "VARIANT", "TIMESTAMP_TZ",
        "TIMESTAMP_LTZ", "TIME", "BINARY", "OBJECT", "ARRAY", "GEOGRAPHY", "GEOMETRY",
    ];

    /// <summary>The statements for one change. <paramref name="qualify"/> spells a table with its database and schema.</summary>
    public static IReadOnlyList<string> Build(ObjectName table, SchemaChange change, Func<ObjectName, string> qualify)
    {
        var target = qualify(table);
        return change switch
        {
            CreateTable create => create.Columns.Count == 0 ? [] : [CreateTable(qualify(create.Table), create.Columns)],
            AddColumn add => [string.Concat("ALTER TABLE ", target, " ADD COLUMN ", ColumnSql(add.Column))],
            DropColumn drop => [string.Concat("ALTER TABLE ", target, " DROP COLUMN ", Q(drop.Column))],
            RenameColumn rename => [RenameColumn(target, rename.From, rename.To)],
            AlterColumn alter => AlterColumn(target, alter.Before, alter.After),

            // Snowflake accepts a qualified new name as a move, so the new name is qualified the same way to rename in place.
            RenameTable rename => [string.Concat("ALTER TABLE ", target, " RENAME TO ", qualify(table with { Name = rename.NewName }))],
            DropObject drop => DropObject(qualify(drop.Object.Name), drop.Object, drop.Cascade) is { } sql ? [sql] : [],
            TruncateTable => ["TRUNCATE TABLE " + target],

            // Snowflake has no indexes, and the macOS app declares foreign keys only when it creates a table.
            _ => [],
        };
    }

    /// <summary>AUTOINCREMENT replaces a default, and Snowflake writes DEFAULT before NOT NULL and COMMENT last.</summary>
    public static string ColumnSql(ColumnDefinition column)
    {
        var sql = new StringBuilder(Q(column.Name)).Append(' ').Append(column.DataType.Trim());
        if (column.IsIdentity)
        {
            sql.Append(" AUTOINCREMENT");
        }
        else if (!string.IsNullOrWhiteSpace(column.DefaultExpression))
        {
            sql.Append(" DEFAULT ").Append(column.DefaultExpression.Trim());
        }

        if (!column.IsNullable)
        {
            sql.Append(" NOT NULL");
        }

        if (!string.IsNullOrEmpty(column.Comment))
        {
            sql.Append(" COMMENT ").Append(SnowflakeSql.Literal(column.Comment));
        }

        return sql.ToString();
    }

    public static string CreateTable(string target, IReadOnlyList<ColumnDefinition> columns)
    {
        var entries = columns.Select(ColumnSql).ToList();
        var keys = columns.Where(c => c.IsPrimaryKey).Select(c => Q(c.Name)).ToArray();
        if (keys.Length > 0)
        {
            entries.Add(string.Concat("PRIMARY KEY (", string.Join(", ", keys), ")"));
        }

        return string.Concat("CREATE TABLE ", target, " (\n  ", string.Join(",\n  ", entries), "\n)");
    }

    public static string RenameColumn(string target, string from, string to) =>
        string.Concat("ALTER TABLE ", target, " RENAME COLUMN ", Q(from), " TO ", Q(to));

    /// <summary>
    /// A rename first, then one ALTER carrying every attribute change under the new name. A new default cannot be set
    /// on an existing column (only dropped), and a type change outside Snowflake's rules is refused, so either makes
    /// the whole edit empty rather than half applied.
    /// </summary>
    public static IReadOnlyList<string> AlterColumn(string target, ColumnDefinition before, ColumnDefinition after)
    {
        var statements = new List<string>(2);
        if (!string.Equals(before.Name, after.Name, StringComparison.Ordinal))
        {
            statements.Add(RenameColumn(target, before.Name, after.Name));
        }

        var column = "COLUMN " + Q(after.Name);
        var actions = new List<string>(4);
        if (!string.Equals(Normalize(before.DataType), Normalize(after.DataType), StringComparison.Ordinal))
        {
            if (!IsSupportedTypeChange(before.DataType, after.DataType))
            {
                return [];
            }

            actions.Add(string.Concat(column, " SET DATA TYPE ", after.DataType.Trim()));
        }

        if (before.IsNullable != after.IsNullable)
        {
            actions.Add(string.Concat(column, after.IsNullable ? " DROP NOT NULL" : " SET NOT NULL"));
        }

        if (!string.Equals(before.Comment ?? string.Empty, after.Comment ?? string.Empty, StringComparison.Ordinal))
        {
            actions.Add(string.IsNullOrEmpty(after.Comment) ? column + " UNSET COMMENT" : string.Concat(column, " COMMENT ", SnowflakeSql.Literal(after.Comment)));
        }

        var beforeDefault = Blank(before.DefaultExpression);
        var afterDefault = Blank(after.DefaultExpression);
        if (!string.Equals(beforeDefault, afterDefault, StringComparison.Ordinal))
        {
            if (afterDefault is not null)
            {
                return [];
            }

            actions.Add(column + " DROP DEFAULT");
        }

        if (actions.Count > 0)
        {
            statements.Add(string.Concat("ALTER TABLE ", target, " ALTER ", string.Join(", ", actions)));
        }

        return statements;
    }

    /// <summary>Snowflake widens a text column and changes a number's precision at the same scale; nothing else.</summary>
    public static bool IsSupportedTypeChange(string from, string to)
    {
        var (oldBase, oldArguments) = Parse(from);
        var (newBase, newArguments) = Parse(to);
        if (oldBase != newBase)
        {
            return false;
        }

        return oldBase switch
        {
            "VARCHAR" or "STRING" or "TEXT" or "CHAR" or "CHARACTER" =>
                (newArguments.Length > 0 ? newArguments[0] : MaxTextLength) >= (oldArguments.Length > 0 ? oldArguments[0] : MaxTextLength),
            "NUMBER" or "DECIMAL" or "NUMERIC" =>
                (oldArguments.Length > 1 ? oldArguments[1] : 0) == (newArguments.Length > 1 ? newArguments[1] : 0),
            _ => false,
        };
    }

    public static string? DropObject(string target, DatabaseObject obj, bool cascade)
    {
        var suffix = cascade ? " CASCADE" : string.Empty;
        return obj.Kind switch
        {
            ObjectKind.Table => string.Concat("DROP TABLE ", target, suffix),
            ObjectKind.View => "DROP VIEW " + target,
            ObjectKind.MaterializedView => "DROP MATERIALIZED VIEW " + target,
            ObjectKind.Sequence => string.Concat("DROP SEQUENCE ", target, suffix),

            // A routine is overloaded by its argument types, which the sidebar keeps from SHOW's arguments column.
            ObjectKind.Function => string.Concat("DROP FUNCTION ", target, SnowflakeSql.ArgumentTypes(obj.Comment)),
            ObjectKind.Procedure => string.Concat("DROP PROCEDURE ", target, SnowflakeSql.ArgumentTypes(obj.Comment)),
            _ => null,
        };
    }

    private static (string Base, long[] Arguments) Parse(string type)
    {
        var upper = type.Trim().ToUpperInvariant();
        var open = upper.IndexOf('(', StringComparison.Ordinal);
        if (open < 0 || !upper.EndsWith(')'))
        {
            return (upper, []);
        }

        var arguments = new List<long>(2);
        foreach (var part in upper[(open + 1)..^1].Split(',', StringSplitOptions.TrimEntries))
        {
            if (long.TryParse(part, NumberStyles.Integer, CultureInfo.InvariantCulture, out var value))
            {
                arguments.Add(value);
            }
        }

        return (upper[..open].Trim(), [.. arguments]);
    }

    private static string Normalize(string type) => type.Replace(" ", string.Empty, StringComparison.Ordinal).ToUpperInvariant();

    private static string? Blank(string? value) => string.IsNullOrWhiteSpace(value) ? null : value.Trim();

    private static string Q(string identifier) => SnowflakeSql.Quote(identifier);
}
