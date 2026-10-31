using System.Collections.Frozen;
using TablePro.Core.Schema;

namespace TablePro.Drivers.Cassandra;

/// <summary>One row of <c>system_schema.columns</c>.</summary>
public sealed record CqlColumnRow(string Name, string Type, string Kind, int Position, string? ClusteringOrder = null)
{
    public bool IsPartitionKey => Kind == "partition_key";

    public bool IsClustering => Kind == "clustering";

    public bool IsStatic => Kind == "static";

    public bool IsPrimaryKey => IsPartitionKey || IsClustering;

    public bool IsDescending => string.Equals(ClusteringOrder, "desc", StringComparison.OrdinalIgnoreCase);
}

/// <summary>One row of <c>system_schema.indexes</c>.</summary>
public sealed record CqlIndexRow(string Name, string Kind, IReadOnlyDictionary<string, string> Options)
{
    public string Target => Options.TryGetValue("target", out var target) ? target : string.Empty;
}

/// <summary>What browsing, saving and DDL need to know about a table: its columns and how its key is built.</summary>
public sealed class CqlTableShape
{
    private static readonly FrozenSet<string> NativeTypes = FrozenSet.Create(
        StringComparer.OrdinalIgnoreCase,
        ["ascii", "bigint", "blob", "boolean", "counter", "date", "decimal", "double", "duration", "float", "inet", "int",
         "smallint", "text", "time", "timestamp", "timeuuid", "tinyint", "uuid", "varchar", "varint"]);

    private readonly Dictionary<string, CqlColumnRow> _byName;

    public CqlTableShape(ObjectName table, IEnumerable<CqlColumnRow> columns)
    {
        Table = table;
        Columns = Order(columns);
        _byName = Columns.ToDictionary(c => c.Name, StringComparer.Ordinal);
        PartitionKey = [.. Columns.Where(c => c.IsPartitionKey).Select(c => c.Name)];
        ClusteringKey = [.. Columns.Where(c => c.IsClustering).Select(c => c.Name)];
        PrimaryKey = [.. PartitionKey, .. ClusteringKey];
    }

    public ObjectName Table { get; }

    /// <summary>Partition key, clustering columns, then static and regular columns by name, as DESCRIBE orders them.</summary>
    public IReadOnlyList<CqlColumnRow> Columns { get; }

    public IReadOnlyList<string> PartitionKey { get; }

    public IReadOnlyList<string> ClusteringKey { get; }

    public IReadOnlyList<string> PrimaryKey { get; }

    public bool HasCounters => Columns.Any(c => c.Type.Equals("counter", StringComparison.OrdinalIgnoreCase));

    public CqlColumnRow? Column(string name) => _byName.GetValueOrDefault(name);

    /// <summary>Collections, tuples, vectors and user-defined types travel as JSON text in the grid.</summary>
    public bool IsComposite(string column) => _byName.TryGetValue(column, out var row) && IsCompositeType(row.Type);

    public static bool IsCompositeType(string type) => !NativeTypes.Contains(type.Trim());

    public static IReadOnlyList<CqlColumnRow> Order(IEnumerable<CqlColumnRow> columns)
    {
        var all = columns.ToList();
        return
        [
            .. all.Where(c => c.IsPartitionKey).OrderBy(c => c.Position),
            .. all.Where(c => c.IsClustering).OrderBy(c => c.Position),
            .. all.Where(c => c.IsStatic).OrderBy(c => c.Name, StringComparer.Ordinal),
            .. all.Where(c => !c.IsPrimaryKey && !c.IsStatic).OrderBy(c => c.Name, StringComparer.Ordinal),
        ];
    }

    /// <summary>The structure tab's view: key columns marked as the primary key, their role in the type text.</summary>
    public IReadOnlyList<ColumnInfo> ToColumnInfos()
    {
        var list = new List<ColumnInfo>(Columns.Count);
        for (var i = 0; i < Columns.Count; i++)
        {
            var column = Columns[i];
            list.Add(new ColumnInfo(column.Name, DescribeType(column), !column.IsPrimaryKey, null, column.IsPrimaryKey, false, i));
        }

        return list;
    }

    public static string DescribeType(CqlColumnRow column)
    {
        if (column.IsPartitionKey)
        {
            return column.Type + " (partition key)";
        }

        if (column.IsClustering)
        {
            return column.Type + (column.IsDescending ? " (clustering DESC)" : " (clustering ASC)");
        }

        return column.IsStatic ? column.Type + " (static)" : column.Type;
    }

    /// <summary>Removes the role <see cref="DescribeType"/> appends, so an edited structure row yields a plain CQL type.</summary>
    public static string StripRole(string type)
    {
        foreach (var suffix in (ReadOnlySpan<string>)[" (partition key)", " (clustering ASC)", " (clustering DESC)", " (static)"])
        {
            if (type.EndsWith(suffix, StringComparison.Ordinal))
            {
                return type[..^suffix.Length];
            }
        }

        return type;
    }
}
