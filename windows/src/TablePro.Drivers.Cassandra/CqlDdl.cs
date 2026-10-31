using System.Collections;
using System.Globalization;
using System.Text;
using TablePro.Core.Schema;
using TablePro.Core.Sql;

namespace TablePro.Drivers.Cassandra;

/// <summary>
/// Structure edits as CQL. CQL has no column defaults, NOT NULL, foreign keys or table renames, and changes a column's
/// type only in releases before 3.10, so those edits produce no statement and the review sheet shows nothing to run.
/// </summary>
public static class CqlDdl
{
    public static readonly IReadOnlyList<string> CommonDataTypes =
    [
        "text", "int", "bigint", "uuid", "timeuuid", "timestamp", "boolean", "double", "float", "decimal", "varint", "date", "time",
        "blob", "inet", "smallint", "tinyint", "duration", "ascii", "counter", "list<text>", "set<text>", "map<text, text>",
    ];

    private static SqlDialect Dialect => CqlDialect.Instance;

    public static IReadOnlyList<string> Build(ObjectName table, SchemaChange change)
    {
        var target = Dialect.Qualify(table);
        return change switch
        {
            CreateTable create => CreateTableStatement(create.Table.Schema is null ? create.Table with { Schema = table.Schema } : create.Table, create.Columns),
            AddColumn add => [$"ALTER TABLE {target} ADD {Q(add.Column.Name)} {Type(add.Column.DataType)}"],
            DropColumn drop => [$"ALTER TABLE {target} DROP {Q(drop.Column)}"],
            RenameColumn rename => [$"ALTER TABLE {target} RENAME {Q(rename.From)} TO {Q(rename.To)}"],
            AlterColumn alter when alter.Before.Name != alter.After.Name => [$"ALTER TABLE {target} RENAME {Q(alter.Before.Name)} TO {Q(alter.After.Name)}"],
            AlterColumn => [],
            CreateIndex index when index.Index.Columns.Count == 1 && !index.Index.IsUnique =>
                [$"CREATE INDEX {Q(index.Index.Name)} ON {target} ({Q(index.Index.Columns[0])})"],
            CreateIndex => [],
            DropIndex drop => [$"DROP INDEX {Qualify(table.Schema, drop.Index)}"],
            TruncateTable => [$"TRUNCATE TABLE {target}"],
            DropObject drop => DropStatement(drop.Object),
            _ => [],
        };
    }

    public static IReadOnlyList<string> CreateTableStatement(ObjectName table, IReadOnlyList<ColumnDefinition> columns)
    {
        var keys = columns.Where(c => c.IsPrimaryKey).Select(c => c.Name).ToList();
        if (keys.Count == 0 || columns.Count == 0)
        {
            return [];
        }

        var sql = new StringBuilder("CREATE TABLE ").Append(Dialect.Qualify(table)).Append(" (\n");
        foreach (var column in columns)
        {
            sql.Append("  ").Append(Q(column.Name)).Append(' ').Append(Type(column.DataType)).Append(",\n");
        }

        // The first key column partitions the table and the rest cluster within it, as the form lists them.
        sql.Append("  PRIMARY KEY (").Append(Q(keys[0]));
        foreach (var clustering in keys.Skip(1))
        {
            sql.Append(", ").Append(Q(clustering));
        }

        return [sql.Append(")\n)").ToString()];
    }

    /// <summary>CREATE TABLE as DESCRIBE writes it, from the server's schema tables, followed by its secondary indexes.</summary>
    public static string TableDefinition(CqlTableShape shape, IReadOnlyList<KeyValuePair<string, object?>> options, IReadOnlyList<CqlIndexRow> indexes)
    {
        var sql = new StringBuilder("CREATE TABLE ").Append(Dialect.Qualify(shape.Table)).Append(" (\n");
        foreach (var column in shape.Columns)
        {
            sql.Append("    ").Append(Q(column.Name)).Append(' ').Append(column.Type);
            if (column.IsStatic)
            {
                sql.Append(" static");
            }

            sql.Append(",\n");
        }

        sql.Append("    PRIMARY KEY (").Append(PrimaryKeyText(shape)).Append(")\n)");
        AppendOptions(sql, shape, options);
        sql.Append(';');

        foreach (var index in indexes)
        {
            sql.Append("\n\n").Append(IndexDefinition(shape.Table, index));
        }

        return sql.ToString();
    }

    public static string ViewDefinition(
        CqlTableShape shape,
        string baseTable,
        string? whereClause,
        bool includeAllColumns,
        IReadOnlyList<KeyValuePair<string, object?>> options)
    {
        var select = includeAllColumns ? "*" : string.Join(", ", shape.Columns.Select(c => Q(c.Name)));
        var sql = new StringBuilder("CREATE MATERIALIZED VIEW ").Append(Dialect.Qualify(shape.Table)).Append(" AS\n")
            .Append("    SELECT ").Append(select).Append(" FROM ").Append(Qualify(shape.Table.Schema, baseTable)).Append('\n');
        if (!string.IsNullOrWhiteSpace(whereClause))
        {
            sql.Append("    WHERE ").Append(whereClause).Append('\n');
        }

        sql.Append("    PRIMARY KEY (").Append(PrimaryKeyText(shape)).Append(')');
        AppendOptions(sql, shape, options);
        return sql.Append(';').ToString();
    }

    public static string IndexDefinition(ObjectName table, CqlIndexRow index)
    {
        var target = Dialect.Qualify(table);
        if (!index.Kind.Equals("CUSTOM", StringComparison.OrdinalIgnoreCase))
        {
            return $"CREATE INDEX {Q(index.Name)} ON {target} ({index.Target});";
        }

        var className = index.Options.GetValueOrDefault("class_name", string.Empty);
        var rest = index.Options.Where(o => o.Key is not ("target" or "class_name")).OrderBy(o => o.Key, StringComparer.Ordinal).ToList();
        var sql = $"CREATE CUSTOM INDEX {Q(index.Name)} ON {target} ({index.Target}) USING {Dialect.StringLiteral(className)}";
        return rest.Count == 0 ? sql + ";" : $"{sql} WITH OPTIONS = {MapLiteral(rest)};";
    }

    public static string KeyspaceDefinition(string keyspace, IReadOnlyDictionary<string, string> replication, bool durableWrites) =>
        $"CREATE KEYSPACE {Q(keyspace)} WITH replication = {MapLiteral(replication.OrderBy(r => r.Key == "class" ? string.Empty : r.Key, StringComparer.Ordinal))}"
        + $" AND durable_writes = {(durableWrites ? "true" : "false")};";

    public static string TypeDefinition(ObjectName type, IReadOnlyList<string> fieldNames, IReadOnlyList<string> fieldTypes)
    {
        var sql = new StringBuilder("CREATE TYPE ").Append(Dialect.Qualify(type)).Append(" (\n");
        for (var i = 0; i < fieldNames.Count; i++)
        {
            sql.Append("    ").Append(Q(fieldNames[i])).Append(' ').Append(i < fieldTypes.Count ? fieldTypes[i] : "text");
            sql.Append(i < fieldNames.Count - 1 ? ",\n" : "\n");
        }

        return sql.Append(");").ToString();
    }

    public static string FunctionDefinition(
        ObjectName function,
        IReadOnlyList<string> argumentNames,
        IReadOnlyList<string> argumentTypes,
        bool calledOnNullInput,
        string returnType,
        string language,
        string body)
    {
        var arguments = string.Join(", ", argumentNames.Select((name, i) => $"{Q(name)} {(i < argumentTypes.Count ? argumentTypes[i] : "text")}"));
        return $"CREATE FUNCTION {Dialect.Qualify(function)}({arguments})\n"
            + $"    {(calledOnNullInput ? "CALLED" : "RETURNS NULL")} ON NULL INPUT\n"
            + $"    RETURNS {returnType}\n"
            + $"    LANGUAGE {language}\n"
            + $"    AS $${body}$$;";
    }

    public static string AggregateDefinition(
        ObjectName aggregate,
        IReadOnlyList<string> argumentTypes,
        string stateFunction,
        string stateType,
        string? finalFunction,
        string? initialCondition)
    {
        var sql = new StringBuilder("CREATE AGGREGATE ").Append(Dialect.Qualify(aggregate)).Append('(').AppendJoin(", ", argumentTypes).Append(")\n")
            .Append("    SFUNC ").Append(Q(stateFunction)).Append('\n')
            .Append("    STYPE ").Append(stateType);
        if (!string.IsNullOrEmpty(finalFunction))
        {
            sql.Append("\n    FINALFUNC ").Append(Q(finalFunction));
        }

        if (!string.IsNullOrEmpty(initialCondition))
        {
            sql.Append("\n    INITCOND ").Append(initialCondition);
        }

        return sql.Append(';').ToString();
    }

    /// <summary>A CQL literal for a schema option value read from <c>system_schema</c>.</summary>
    public static string OptionLiteral(object? value) => value switch
    {
        null => "null",
        string s => Dialect.StringLiteral(s),
        bool b => b ? "true" : "false",
        double d => d.ToString("R", CultureInfo.InvariantCulture),
        float f => f.ToString("R", CultureInfo.InvariantCulture),
        IFormattable number when value.GetType().IsPrimitive || value is decimal => number.ToString(null, CultureInfo.InvariantCulture),
        IDictionary map => MapLiteral(map.Keys.Cast<object>()
            .Select(k => new KeyValuePair<string, string>(Convert.ToString(k, CultureInfo.InvariantCulture) ?? string.Empty, Convert.ToString(map[k], CultureInfo.InvariantCulture) ?? string.Empty))
            .OrderBy(e => e.Key, StringComparer.Ordinal)),
        IEnumerable items => "{" + string.Join(", ", items.Cast<object?>().Select(OptionLiteral)) + "}",
        _ => Dialect.StringLiteral(Convert.ToString(value, CultureInfo.InvariantCulture) ?? string.Empty),
    };

    private static IReadOnlyList<string> DropStatement(DatabaseObject obj) => obj.Kind switch
    {
        ObjectKind.Table => [$"DROP TABLE {Dialect.Qualify(obj.Name)}"],
        ObjectKind.MaterializedView or ObjectKind.View => [$"DROP MATERIALIZED VIEW {Dialect.Qualify(obj.Name)}"],
        ObjectKind.Function when CassandraObjects.IsUserType(obj) => [$"DROP TYPE {Dialect.Qualify(obj.Name)}"],
        ObjectKind.Function when CassandraObjects.IsAggregate(obj) => [$"DROP AGGREGATE {Dialect.Qualify(obj.Name)}"],
        ObjectKind.Function => [$"DROP FUNCTION {Dialect.Qualify(obj.Name)}"],
        _ => [],
    };

    private static string PrimaryKeyText(CqlTableShape shape)
    {
        var partition = shape.PartitionKey.Count == 1 ? Q(shape.PartitionKey[0]) : "(" + string.Join(", ", shape.PartitionKey.Select(Q)) + ")";
        return shape.ClusteringKey.Count == 0 ? partition : partition + ", " + string.Join(", ", shape.ClusteringKey.Select(Q));
    }

    private static void AppendOptions(StringBuilder sql, CqlTableShape shape, IReadOnlyList<KeyValuePair<string, object?>> options)
    {
        var clauses = new List<string>();
        if (shape.ClusteringKey.Count > 0)
        {
            var order = shape.Columns.Where(c => c.IsClustering).Select(c => $"{Q(c.Name)} {(c.IsDescending ? "DESC" : "ASC")}");
            clauses.Add($"CLUSTERING ORDER BY ({string.Join(", ", order)})");
        }

        foreach (var (name, value) in options.OrderBy(o => o.Key, StringComparer.Ordinal))
        {
            if (value is not null && !SkippedOptions.Contains(name))
            {
                clauses.Add($"{name} = {OptionLiteral(value)}");
            }
        }

        for (var i = 0; i < clauses.Count; i++)
        {
            sql.Append(i == 0 ? " WITH " : "\n    AND ").Append(clauses[i]);
        }
    }

    // Identity and bookkeeping columns of system_schema.tables and .views, which are not table options.
    private static readonly HashSet<string> SkippedOptions = new(StringComparer.Ordinal)
    {
        "keyspace_name", "table_name", "view_name", "id", "flags", "extensions", "base_table_id", "base_table_name", "include_all_columns", "where_clause",
    };

    private static string MapLiteral(IEnumerable<KeyValuePair<string, string>> entries) =>
        "{" + string.Join(", ", entries.Select(e => $"{Dialect.StringLiteral(e.Key)}: {Dialect.StringLiteral(e.Value)}")) + "}";

    private static string Type(string dataType) => CqlTableShape.StripRole(dataType).Trim();

    private static string Q(string identifier) => Dialect.QuoteIdentifier(identifier);

    private static string Qualify(string? keyspace, string name) => Dialect.Qualify(new ObjectName(keyspace, name));
}
