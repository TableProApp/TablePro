using System.Globalization;
using System.Text;
using TablePro.Core.Schema;
using TablePro.Core.Sql;

namespace TablePro.Drivers.PostgreSql;

/// <summary>The PostgreSQL statements for each structure change. Pure, so the text is pinned by unit tests.</summary>
internal static class PostgreSqlDdl
{
    public static readonly IReadOnlyList<string> CommonDataTypes =
    [
        "integer", "bigint", "text", "varchar(255)", "boolean", "numeric(12,2)", "timestamptz", "timestamp", "date", "uuid", "jsonb",
        "smallint", "double precision", "real", "time", "interval", "bytea", "json", "inet", "text[]",
    ];

    private static SqlDialect Dialect => PostgreSqlDialect.Instance;

    public static IReadOnlyList<string> Build(ObjectName table, SchemaChange change) => change switch
    {
        CreateTable create => CreateTable(create),
        AddColumn add => AddColumn(table, add.Column),
        DropColumn drop => [string.Concat(AlterTable(table), " DROP COLUMN ", Q(drop.Column))],
        RenameColumn rename => [RenameColumn(table, rename.From, rename.To)],
        AlterColumn alter => AlterColumn(table, alter.Before, alter.After),
        CreateIndex index => [CreateIndex(table, index.Index)],
        DropIndex index => ["DROP INDEX " + Dialect.Qualify(new ObjectName(table.Schema, index.Index))],
        AddForeignKey key => [string.Concat(AlterTable(table), " ADD ", ForeignKey(table, key.ForeignKey))],
        DropForeignKey key => [string.Concat(AlterTable(table), " DROP CONSTRAINT ", Q(key.Name))],
        RenameTable rename => [string.Concat(AlterTable(table), " RENAME TO ", Q(rename.NewName))],
        DropObject drop => DropObject(table, drop.Object, drop.Cascade) is { } sql ? [sql] : [],
        TruncateTable truncate => [string.Concat("TRUNCATE TABLE ", Dialect.Qualify(table), truncate.Cascade ? " CASCADE" : string.Empty)],
        AddCheckConstraint add => add.Constraint.IsComplete ? [string.Concat(AlterTable(table), " ADD ", CheckClause(add.Constraint))] : [],
        DropCheckConstraint drop => [string.Concat(AlterTable(table), " DROP CONSTRAINT ", Q(drop.Name))],
        AlterCheckConstraint alter => AlterCheck(table, alter),
        AddPartition add => AddPartition(table, add.Partition) is { } sql ? [sql] : [],
        DropPartition drop => drop.Partition.IsRelation ? ["DROP TABLE " + Dialect.Qualify(PartitionTable(table, drop.Partition))] : [],
        TruncatePartition truncate => truncate.Partition.IsRelation ? ["TRUNCATE TABLE " + Dialect.Qualify(PartitionTable(table, truncate.Partition))] : [],
        SetTableOptions options => SetOptions(table, options.Changes),
        _ => [],
    };

    public static readonly IReadOnlyList<TableOptionSpec> TableOptionSpecs =
    [
        new(TableOptionNames.Comment, TableOptionKind.Text),
        new(TableOptionNames.Tablespace, TableOptionKind.Text, Placeholder: "pg_default"),
        new(TableOptionNames.FillFactor, TableOptionKind.Number, Placeholder: "100"),
        new(TableOptionNames.Persistence, TableOptionKind.Choice, ["LOGGED", "UNLOGGED"]),
        new(TableOptionNames.StorageParameters, TableOptionKind.Text, Placeholder: "autovacuum_enabled=false, toast_tuple_target=4096"),
    ];

    private const string FillFactorParameter = "fillfactor";

    public static string CheckClause(CheckConstraintDefinition check) =>
        string.Concat("CONSTRAINT ", Q(check.Name.Trim()), " CHECK (", check.Expression.Trim(), ")");

    /// <summary>
    /// A rename keeps the constraint as it is. A new expression drops and adds it in one ALTER TABLE, which PostgreSQL
    /// runs atomically, so a row that fails the new check leaves the old one in place.
    /// </summary>
    public static List<string> AlterCheck(ObjectName table, AlterCheckConstraint alter)
    {
        if (alter.IsRenameOnly)
        {
            return [string.Concat(AlterTable(table), " RENAME CONSTRAINT ", Q(alter.Before.Name), " TO ", Q(alter.After.Name.Trim()))];
        }

        return alter.After.IsComplete
            ? [string.Concat(AlterTable(table), " DROP CONSTRAINT ", Q(alter.Before.Name), ", ADD ", CheckClause(alter.After))]
            : [];
    }

    /// <summary>
    /// A new partition is a table created as a partition of this one, in the same schema. The bound is what
    /// <c>pg_get_expr(relpartbound)</c> prints, so <c>FOR VALUES</c> is added when the user starts at FROM, IN or WITH.
    /// </summary>
    public static string? AddPartition(ObjectName table, PartitionDefinition partition)
    {
        var bound = partition.Bound.Trim();
        if (string.IsNullOrWhiteSpace(partition.Name) || bound.Length == 0)
        {
            return null;
        }

        if (!bound.StartsWith("FOR VALUES", StringComparison.OrdinalIgnoreCase) && !bound.Equals("DEFAULT", StringComparison.OrdinalIgnoreCase))
        {
            bound = "FOR VALUES " + bound;
        }

        return string.Concat(
            "CREATE TABLE ", Dialect.Qualify(table with { Name = partition.Name.Trim() }), " PARTITION OF ", Dialect.Qualify(table), " ", bound);
    }

    /// <summary>The storage parameters go in one SET and one RESET; the tablespace, persistence and comment have statements of their own.</summary>
    public static List<string> SetOptions(ObjectName table, IReadOnlyList<TableOptionChange> changes)
    {
        var set = new List<string>();
        var reset = new List<string>();
        var statements = new List<string>();
        foreach (var change in changes)
        {
            switch (change.Name)
            {
                case TableOptionNames.FillFactor when change.Clears:
                    reset.Add(FillFactorParameter);
                    break;
                case TableOptionNames.FillFactor:
                    set.Add(string.Concat(FillFactorParameter, "=", Number(change.After!, 10, 100, TableOptionNames.FillFactor)));
                    break;
                case TableOptionNames.StorageParameters:
                    DiffParameters(change, set, reset);
                    break;
            }
        }

        if (set.Count > 0)
        {
            statements.Add(string.Concat(AlterTable(table), " SET (", string.Join(", ", set), ")"));
        }

        if (reset.Count > 0)
        {
            statements.Add(string.Concat(AlterTable(table), " RESET (", string.Join(", ", reset), ")"));
        }

        foreach (var change in changes)
        {
            switch (change.Name)
            {
                case TableOptionNames.Tablespace:
                    statements.Add(string.Concat(AlterTable(table), " SET TABLESPACE ", Q(change.Clears ? "pg_default" : change.After!.Trim())));
                    break;
                case TableOptionNames.Persistence:
                    var persistence = change.After?.Trim().ToUpperInvariant();
                    statements.Add(persistence is "LOGGED" or "UNLOGGED"
                        ? string.Concat(AlterTable(table), " SET ", persistence)
                        : throw new ArgumentException("Persistence is LOGGED or UNLOGGED."));
                    break;
                case TableOptionNames.Comment:
                    statements.Add(string.Concat(
                        "COMMENT ON TABLE ", Dialect.Qualify(table), " IS ", change.Clears ? "NULL" : Dialect.StringLiteral(change.After!.Trim())));
                    break;
            }
        }

        return statements;
    }

    /// <summary>
    /// The options the catalog row describes. Fill factor is shown on its own, so it is taken out of the storage
    /// parameters it is stored among.
    /// </summary>
    public static List<TableOption> ReadOptions(string? tablespace, IReadOnlyList<string> relOptions, string persistence, string? comment)
    {
        string? fillFactor = null;
        var others = new List<string>();
        foreach (var option in relOptions)
        {
            var equals = option.IndexOf('=', StringComparison.Ordinal);
            if (equals > 0 && option.AsSpan(0, equals).Equals(FillFactorParameter, StringComparison.OrdinalIgnoreCase))
            {
                fillFactor = option[(equals + 1)..];
            }
            else
            {
                others.Add(option);
            }
        }

        return
        [
            new(TableOptionNames.Comment, comment),
            new(TableOptionNames.Tablespace, tablespace),
            new(TableOptionNames.FillFactor, fillFactor),
            new(TableOptionNames.Persistence, persistence switch { "u" => "UNLOGGED", "t" => "TEMPORARY", _ => "LOGGED" }),
            new(TableOptionNames.StorageParameters, others.Count == 0 ? null : string.Join(", ", others)),
        ];
    }

    /// <summary>Splits <c>pg_get_partkeydef</c>'s <c>RANGE (created_at)</c> into the method and the key.</summary>
    public static (string Method, string Key) SplitPartitionKey(string definition)
    {
        var text = definition.Trim();
        var open = text.IndexOf('(', StringComparison.Ordinal);
        if (open < 0 || !text.EndsWith(')'))
        {
            return (text, string.Empty);
        }

        return (text[..open].Trim(), text[(open + 1)..^1].Trim());
    }

    private static ObjectName PartitionTable(ObjectName table, PartitionInfo partition) =>
        new(string.IsNullOrEmpty(partition.Schema) ? table.Schema : partition.Schema, partition.Name);

    private static void DiffParameters(TableOptionChange change, List<string> set, List<string> reset)
    {
        var before = ParseParameters(change.Before);
        var after = ParseParameters(change.After);
        foreach (var (key, _) in before)
        {
            if (!after.Exists(p => string.Equals(p.Key, key, StringComparison.OrdinalIgnoreCase)))
            {
                reset.Add(key);
            }
        }

        foreach (var (key, value) in after)
        {
            if (!before.Exists(p => string.Equals(p.Key, key, StringComparison.OrdinalIgnoreCase) && string.Equals(p.Value, value, StringComparison.Ordinal)))
            {
                set.Add(string.Concat(key, "=", ParameterValue(value)));
            }
        }
    }

    /// <summary>Reads <c>key=value</c> pairs separated by commas. A key is a plain or dotted name, such as <c>toast.autovacuum_enabled</c>.</summary>
    public static List<(string Key, string Value)> ParseParameters(string? text)
    {
        var pairs = new List<(string, string)>();
        if (string.IsNullOrWhiteSpace(text))
        {
            return pairs;
        }

        foreach (var part in text.Split(',', StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries))
        {
            var equals = part.IndexOf('=', StringComparison.Ordinal);
            var key = equals > 0 ? part[..equals].Trim() : string.Empty;
            if (key.Length == 0 || !IsParameterName(key))
            {
                throw new ArgumentException($"\"{part}\" is not a storage parameter. Write each as name=value.");
            }

            pairs.Add((key.ToLowerInvariant(), part[(equals + 1)..].Trim()));
        }

        return pairs;
    }

    private static bool IsParameterName(string key)
    {
        foreach (var c in key)
        {
            if (!char.IsAsciiLetterOrDigit(c) && c is not '_' and not '.')
            {
                return false;
            }
        }

        return char.IsAsciiLetter(key[0]) || key[0] == '_';
    }

    // A number, true, false or a bare word goes in as written; anything else is quoted so it cannot end the list.
    private static string ParameterValue(string value)
    {
        foreach (var c in value)
        {
            if (!char.IsAsciiLetterOrDigit(c) && c is not '_' and not '.' and not '-' and not '+')
            {
                return Dialect.StringLiteral(value);
            }
        }

        return value.Length == 0 ? Dialect.StringLiteral(value) : value;
    }

    private static string Number(string text, int min, int max, string name) =>
        int.TryParse(text.Trim(), NumberStyles.Integer, CultureInfo.InvariantCulture, out var value) && value >= min && value <= max
            ? value.ToString(CultureInfo.InvariantCulture)
            : throw new ArgumentException($"{name} is a whole number from {min} to {max}.");

    public static string ColumnSql(ColumnDefinition column, bool inlinePrimaryKey)
    {
        var sql = new StringBuilder(Q(column.Name)).Append(' ').Append(column.DataType.Trim());
        if (column.IsIdentity)
        {
            sql.Append(" GENERATED BY DEFAULT AS IDENTITY");
        }

        if (!column.IsNullable && !inlinePrimaryKey)
        {
            sql.Append(" NOT NULL");
        }

        if (!column.IsIdentity && !string.IsNullOrWhiteSpace(column.DefaultExpression))
        {
            sql.Append(" DEFAULT ").Append(column.DefaultExpression.Trim());
        }

        if (inlinePrimaryKey)
        {
            sql.Append(" PRIMARY KEY");
        }

        return sql.ToString();
    }

    public static List<string> CreateTable(CreateTable change)
    {
        var primaryKey = new List<string>();
        foreach (var column in change.Columns)
        {
            if (column.IsPrimaryKey)
            {
                primaryKey.Add(column.Name);
            }
        }

        var sql = new StringBuilder("CREATE TABLE ").Append(Dialect.Qualify(change.Table)).Append(" (\n  ");
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
                statements.Add(ColumnComment(change.Table, column.Name, column.Comment));
            }
        }

        return statements;
    }

    public static List<string> AddColumn(ObjectName table, ColumnDefinition column)
    {
        var statements = new List<string>(2) { string.Concat(AlterTable(table), " ADD COLUMN ", ColumnSql(column, column.IsPrimaryKey)) };
        if (!string.IsNullOrEmpty(column.Comment))
        {
            statements.Add(ColumnComment(table, column.Name, column.Comment));
        }

        return statements;
    }

    public static string RenameColumn(ObjectName table, string from, string to) =>
        string.Concat(AlterTable(table), " RENAME COLUMN ", Q(from), " TO ", Q(to));

    /// <summary>
    /// Every property change goes in one ALTER TABLE, which PostgreSQL applies atomically; the comment and a rename
    /// have statements of their own.
    /// </summary>
    public static List<string> AlterColumn(ObjectName table, ColumnDefinition before, ColumnDefinition after)
    {
        var column = Q(before.Name);
        var actions = new List<string>(4);
        if (!string.Equals(before.DataType.Trim(), after.DataType.Trim(), StringComparison.OrdinalIgnoreCase))
        {
            // USING lets a text column become an integer when its values parse, which a bare TYPE refuses.
            var type = after.DataType.Trim();
            actions.Add(string.Concat("ALTER COLUMN ", column, " TYPE ", type, " USING ", column, "::", type));
        }

        if (before.IsIdentity != after.IsIdentity)
        {
            actions.Add(after.IsIdentity
                ? string.Concat("ALTER COLUMN ", column, " ADD GENERATED BY DEFAULT AS IDENTITY")
                : string.Concat("ALTER COLUMN ", column, " DROP IDENTITY IF EXISTS"));
        }

        if (before.IsNullable != after.IsNullable)
        {
            actions.Add(string.Concat("ALTER COLUMN ", column, after.IsNullable ? " DROP NOT NULL" : " SET NOT NULL"));
        }

        if (!after.IsIdentity && !string.Equals(before.DefaultExpression?.Trim(), after.DefaultExpression?.Trim(), StringComparison.Ordinal))
        {
            actions.Add(string.IsNullOrWhiteSpace(after.DefaultExpression)
                ? string.Concat("ALTER COLUMN ", column, " DROP DEFAULT")
                : string.Concat("ALTER COLUMN ", column, " SET DEFAULT ", after.DefaultExpression.Trim()));
        }

        var statements = new List<string>(3);
        if (actions.Count > 0)
        {
            statements.Add(string.Concat(AlterTable(table), " ", string.Join(", ", actions)));
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
            "CREATE ", index.IsUnique ? "UNIQUE " : string.Empty, "INDEX ", Q(index.Name), " ON ", Dialect.Qualify(table),
            " (", JoinQuoted(index.Columns), ")");

    public static string ForeignKey(ObjectName table, ForeignKeyDefinition key)
    {
        var referenced = key.ReferencedTable.Schema is null ? key.ReferencedTable with { Schema = table.Schema } : key.ReferencedTable;
        var sql = new StringBuilder();
        if (!string.IsNullOrEmpty(key.Name))
        {
            sql.Append("CONSTRAINT ").Append(Q(key.Name)).Append(' ');
        }

        sql.Append("FOREIGN KEY (").Append(JoinQuoted(key.Columns)).Append(") REFERENCES ").Append(Dialect.Qualify(referenced))
            .Append(" (").Append(JoinQuoted(key.ReferencedColumns)).Append(')');
        AppendAction(sql, " ON DELETE ", key.OnDelete);
        AppendAction(sql, " ON UPDATE ", key.OnUpdate);
        return sql.ToString();
    }

    public static string? DropObject(ObjectName table, DatabaseObject obj, bool cascade)
    {
        var target = Dialect.Qualify(obj.Name);
        var suffix = cascade ? " CASCADE" : string.Empty;
        return obj.Kind switch
        {
            ObjectKind.Table => string.Concat("DROP TABLE ", target, suffix),
            ObjectKind.View => string.Concat("DROP VIEW ", target, suffix),
            ObjectKind.MaterializedView => string.Concat("DROP MATERIALIZED VIEW ", target, suffix),
            ObjectKind.Function => string.Concat("DROP FUNCTION ", target, suffix),
            ObjectKind.Procedure => string.Concat("DROP PROCEDURE ", target, suffix),
            ObjectKind.Sequence => string.Concat("DROP SEQUENCE ", target, suffix),

            // A trigger belongs to its table; the change is made from that table's structure tab.
            ObjectKind.Trigger => string.Concat("DROP TRIGGER ", Q(obj.Name.Name), " ON ", Dialect.Qualify(table), suffix),
            _ => null,
        };
    }

    public static string ColumnComment(ObjectName table, string column, string? comment) =>
        string.Concat(
            "COMMENT ON COLUMN ", Dialect.Qualify(table), ".", Q(column), " IS ",
            string.IsNullOrEmpty(comment) ? "NULL" : Dialect.StringLiteral(comment));

    public static string CreateDatabase(string name) => "CREATE DATABASE " + Q(name);

    public static string DropDatabase(string name) => "DROP DATABASE " + Q(name);

    public static string Sequence(string qualifiedName, string type, long start, long increment, long min, long max, long cache, bool cycle) =>
        string.Create(
            CultureInfo.InvariantCulture,
            $"CREATE SEQUENCE {qualifiedName} AS {type} INCREMENT BY {increment} MINVALUE {min} MAXVALUE {max} START WITH {start} CACHE {cache}{(cycle ? " CYCLE" : " NO CYCLE")};");

    public static string ReferentialAction(string code) => code switch
    {
        "r" => "RESTRICT",
        "c" => "CASCADE",
        "n" => "SET NULL",
        "d" => "SET DEFAULT",
        _ => "NO ACTION",
    };

    private static void AppendAction(StringBuilder sql, string clause, string? action)
    {
        if (!string.IsNullOrWhiteSpace(action) && !string.Equals(action.Trim(), "NO ACTION", StringComparison.OrdinalIgnoreCase))
        {
            sql.Append(clause).Append(action.Trim().ToUpperInvariant());
        }
    }

    private static string AlterTable(ObjectName table) => "ALTER TABLE " + Dialect.Qualify(table);

    private static string Q(string identifier) => Dialect.QuoteIdentifier(identifier);

    private static string JoinQuoted(IReadOnlyList<string> names)
    {
        var sql = new StringBuilder();
        for (var i = 0; i < names.Count; i++)
        {
            if (i > 0)
            {
                sql.Append(", ");
            }

            sql.Append(Q(names[i]));
        }

        return sql.ToString();
    }
}
