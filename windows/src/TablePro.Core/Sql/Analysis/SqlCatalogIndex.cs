using System.Collections.Frozen;
using System.Runtime.CompilerServices;

namespace TablePro.Core.Sql.Analysis;

/// <summary>
/// The completion catalog keyed for lookups. A catalog is replaced, never changed, so the index is built once per
/// catalog and kept beside it for as long as the catalog lives.
/// </summary>
internal sealed class SqlCatalogIndex
{
    private static readonly ConditionalWeakTable<CompletionCatalog, SqlCatalogIndex> Cache = [];

    private readonly FrozenDictionary<string, bool> _tables;
    private readonly FrozenSet<string> _schemas;
    private readonly FrozenDictionary<string, IReadOnlyList<(string Name, string Type)>> _columns;

    private SqlCatalogIndex(CompletionCatalog catalog)
    {
        var tables = new Dictionary<string, bool>(catalog.Tables.Count, StringComparer.OrdinalIgnoreCase);
        foreach (var (name, isView) in catalog.Tables)
        {
            tables.TryAdd(name, isView);
        }

        _tables = tables.ToFrozenDictionary(StringComparer.OrdinalIgnoreCase);
        _schemas = catalog.Schemas.ToFrozenSet(StringComparer.OrdinalIgnoreCase);
        _columns = catalog.Columns;
    }

    public static SqlCatalogIndex For(CompletionCatalog catalog) => Cache.GetValue(catalog, static c => new SqlCatalogIndex(c));

    /// <summary>False until the sidebar has loaded, when nothing can be called unknown.</summary>
    public bool HasTables => _tables.Count > 0;

    public bool TryGetTable(string name, out bool isView) => _tables.TryGetValue(name, out isView);

    public bool IsSchema(string name) => _schemas.Contains(name);

    /// <summary>The table's columns, or null when its structure has not been loaded and so nothing can be said about them.</summary>
    public IReadOnlyList<(string Name, string Type)>? Columns(string? schema, string table)
    {
        if (schema is not null && _columns.TryGetValue($"{schema}.{table}", out var qualified))
        {
            return qualified;
        }

        return _columns.TryGetValue(table, out var columns) ? columns : null;
    }

    public static (string Name, string Type)? FindColumn(IReadOnlyList<(string Name, string Type)> columns, string name)
    {
        foreach (var column in columns)
        {
            if (string.Equals(column.Name, name, StringComparison.OrdinalIgnoreCase))
            {
                return column;
            }
        }

        return null;
    }
}
