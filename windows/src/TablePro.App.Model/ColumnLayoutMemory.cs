using TablePro.Interop;

namespace TablePro.App.Model;

// The column layouts a table tab reads and keeps, scoped to one connection and database.
public interface ITableColumns
{
    ColumnLayout Recall(TableName table);

    void Remember(TableName table, ColumnLayout layout);
}

public sealed record ColumnLayoutFile
{
    public Dictionary<string, ColumnLayout> Tables { get; set; } = [];
}

// Each table's column order, hidden columns and frozen count, as macOS keeps a table's column layout, so a table opened
// again shows its columns as they were left. One file for every connection, written whole on each change.
public sealed class ColumnLayoutMemory
{
    private readonly string _path;
    private readonly Lock _lock = new();
    private Dictionary<string, ColumnLayout>? _tables;

    public ColumnLayoutMemory(string path)
    {
        ArgumentException.ThrowIfNullOrEmpty(path);
        _path = path;
    }

    public ITableColumns For(string connection, string? database) => new Scope(this, connection, database);

    public ColumnLayout Recall(string connection, string? database, TableName table)
    {
        ArgumentNullException.ThrowIfNull(table);
        lock (_lock)
        {
            return Tables().GetValueOrDefault(TableMemoryKey.Of(connection, database, table.Schema, table.Name))
                ?? ColumnLayout.Default;
        }
    }

    // The default layout forgets the table, as Reset Columns does.
    public void Remember(string connection, string? database, TableName table, ColumnLayout layout)
    {
        ArgumentNullException.ThrowIfNull(table);
        ArgumentNullException.ThrowIfNull(layout);
        var key = TableMemoryKey.Of(connection, database, table.Schema, table.Name);
        lock (_lock)
        {
            var tables = Tables();
            var kept = tables.GetValueOrDefault(key);
            if (layout.IsDefault ? kept is null : kept is not null && Same(kept, layout))
            {
                return;
            }

            if (layout.IsDefault)
            {
                tables.Remove(key);
            }
            else
            {
                tables[key] = layout;
            }

            Write(tables);
        }
    }

    // A dropped table's layout goes with it, so a table made again under its name starts with its own columns.
    public void ForgetTable(string connection, string? database, TableName table)
    {
        ArgumentNullException.ThrowIfNull(table);
        Remember(connection, database, table, ColumnLayout.Default);
    }

    public void ForgetSchema(string connection, string? database, string schema)
    {
        ArgumentNullException.ThrowIfNull(schema);
        ForgetPrefix(TableMemoryKey.Part(connection) + "." + TableMemoryKey.Part(database) + "."
            + TableMemoryKey.Part(schema) + ".");
    }

    public void ForgetDatabase(string connection, string database)
    {
        ArgumentNullException.ThrowIfNull(database);
        ForgetPrefix(TableMemoryKey.Part(connection) + "." + TableMemoryKey.Part(database) + ".");
    }

    // The schemas holding a kept layout under the connection and database; null for a table named with no schema.
    public IReadOnlyList<string?> SchemasWithLayouts(string connection, string? database)
    {
        var prefix = TableMemoryKey.Part(connection) + "." + TableMemoryKey.Part(database) + ".";
        lock (_lock)
        {
            return [.. Tables().Keys
                .Where(key => key.StartsWith(prefix, StringComparison.Ordinal))
                .Select(key => key[prefix.Length..].Split('.')[0])
                .Distinct(StringComparer.Ordinal)
                .Select(part => part.Length == 0 ? null : Uri.UnescapeDataString(part))];
        }
    }

    // A drop can take tables no tab showed, as a partitioned table's partitions, so the schema's kept layouts are
    // matched against what it lists now.
    public void ForgetMissing(string connection, string? database, string? schema, IReadOnlySet<string> present)
    {
        ArgumentNullException.ThrowIfNull(present);
        var prefix = TableMemoryKey.Part(connection) + "." + TableMemoryKey.Part(database) + "."
            + TableMemoryKey.Part(schema) + ".";
        lock (_lock)
        {
            var tables = Tables();
            var gone = tables.Keys
                .Where(key => key.StartsWith(prefix, StringComparison.Ordinal)
                    && !present.Contains(Uri.UnescapeDataString(key[prefix.Length..])))
                .ToList();
            if (gone.Count == 0)
            {
                return;
            }

            foreach (var key in gone)
            {
                tables.Remove(key);
            }

            Write(tables);
        }
    }

    private static bool Same(ColumnLayout left, ColumnLayout right) =>
        left.Frozen == right.Frozen
        && left.Order.SequenceEqual(right.Order, StringComparer.Ordinal)
        && left.Hidden.SequenceEqual(right.Hidden, StringComparer.Ordinal);

    private void ForgetPrefix(string prefix)
    {
        lock (_lock)
        {
            var tables = Tables();
            var gone = tables.Keys.Where(key => key.StartsWith(prefix, StringComparison.Ordinal)).ToList();
            if (gone.Count == 0)
            {
                return;
            }

            foreach (var key in gone)
            {
                tables.Remove(key);
            }

            Write(tables);
        }
    }

    private Dictionary<string, ColumnLayout> Tables() =>
        _tables ??= JsonFile.Read(_path, ModelJson.Default.ColumnLayoutFile)?.Tables is { } read
            ? new Dictionary<string, ColumnLayout>(read, StringComparer.Ordinal)
            : new Dictionary<string, ColumnLayout>(StringComparer.Ordinal);

    // A file another program holds keeps the layout in memory until the next change writes it.
    private void Write(Dictionary<string, ColumnLayout> tables)
    {
        try
        {
            JsonFile.Write(_path, new ColumnLayoutFile { Tables = tables }, ModelJson.Default.ColumnLayoutFile);
        }
        catch (Exception exception) when (exception is IOException or UnauthorizedAccessException)
        {
        }
    }

    private sealed class Scope(ColumnLayoutMemory memory, string connection, string? database) : ITableColumns
    {
        public ColumnLayout Recall(TableName table) => memory.Recall(connection, database, table);

        public void Remember(TableName table, ColumnLayout layout) => memory.Remember(connection, database, table, layout);
    }
}
