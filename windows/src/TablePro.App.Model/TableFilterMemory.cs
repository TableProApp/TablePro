using TablePro.Interop;

namespace TablePro.App.Model;

// The filters a table tab reads and keeps, scoped to one connection and database.
public interface ITableFilters
{
    TableFilter? Recall(TableName table);

    // Null forgets the table's filter, as Clear does.
    void Remember(TableName table, TableFilter? filter);
}

public sealed record TableFilterFile
{
    public Dictionary<string, SavedFilter> Tables { get; set; } = [];
}

// The last filter applied to each table, per connection, database, schema and table, as macOS keeps it, so a table
// opened again reads with it. One file for every connection, written whole on each change.
public sealed class TableFilterMemory
{
    private readonly string _path;
    private readonly Lock _lock = new();
    private Dictionary<string, SavedFilter>? _tables;

    public TableFilterMemory(string path)
    {
        ArgumentException.ThrowIfNullOrEmpty(path);
        _path = path;
    }

    // A saved connection by its id, a file opened without saving by its path; database is the one the session is in.
    public static string ConnectionKey(Guid? connectionId, string? filePath) =>
        connectionId is { } id ? "id:" + id.ToString("D") : "file:" + (filePath ?? string.Empty);

    public ITableFilters For(string connection, string? database) => new Scope(this, connection, database);

    public TableFilter? Recall(string connection, string? database, TableName table)
    {
        ArgumentNullException.ThrowIfNull(table);
        lock (_lock)
        {
            return Tables().GetValueOrDefault(Key(connection, database, table.Schema, table.Name))?.ToFilter();
        }
    }

    public void Remember(string connection, string? database, TableName table, TableFilter? filter)
    {
        ArgumentNullException.ThrowIfNull(table);
        var key = Key(connection, database, table.Schema, table.Name);
        lock (_lock)
        {
            var tables = Tables();
            var kept = tables.GetValueOrDefault(key)?.ToFilter();
            if (filter is null ? !tables.ContainsKey(key) : TableFilters.Same(kept, filter))
            {
                return;
            }

            if (filter is null)
            {
                tables.Remove(key);
            }
            else
            {
                tables[key] = SavedFilter.From(filter);
            }

            Write(tables);
        }
    }

    // A dropped table's filter goes with it, so a table made again under its name starts unfiltered.
    public void ForgetTable(string connection, string? database, TableName table)
    {
        ArgumentNullException.ThrowIfNull(table);
        Remember(connection, database, table, null);
    }

    // Every table of a dropped schema, or of a dropped database where the server's databases are its schemas.
    public void ForgetSchema(string connection, string? database, string schema)
    {
        ArgumentNullException.ThrowIfNull(schema);
        ForgetPrefix(Part(connection) + "." + Part(database) + "." + Part(schema) + ".");
    }

    // Every table of a dropped database whose schemas are its own.
    public void ForgetDatabase(string connection, string database)
    {
        ArgumentNullException.ThrowIfNull(database);
        ForgetPrefix(Part(connection) + "." + Part(database) + ".");
    }

    // The schemas holding a kept filter under the connection and database; null for a table named with no schema.
    public IReadOnlyList<string?> SchemasWithFilters(string connection, string? database)
    {
        var prefix = Part(connection) + "." + Part(database) + ".";
        lock (_lock)
        {
            return [.. Tables().Keys
                .Where(key => key.StartsWith(prefix, StringComparison.Ordinal))
                .Select(key => key[prefix.Length..].Split('.')[0])
                .Distinct(StringComparer.Ordinal)
                .Select(part => part.Length == 0 ? null : Uri.UnescapeDataString(part))];
        }
    }

    // A drop can take tables no tab showed, such as a partitioned table's partitions, so the schema's kept filters are
    // matched against what it lists now.
    public void ForgetMissing(string connection, string? database, string? schema, IReadOnlySet<string> present)
    {
        ArgumentNullException.ThrowIfNull(present);
        var prefix = Part(connection) + "." + Part(database) + "." + Part(schema) + ".";
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

    private static string Key(string connection, string? database, string? schema, string table) =>
        TableMemoryKey.Of(connection, database, schema, table);

    private static string Part(string? part) => TableMemoryKey.Part(part);

    private Dictionary<string, SavedFilter> Tables() =>
        _tables ??= JsonFile.Read(_path, ModelJson.Default.TableFilterFile)?.Tables is { } read
            ? new Dictionary<string, SavedFilter>(read, StringComparer.Ordinal)
            : new Dictionary<string, SavedFilter>(StringComparer.Ordinal);

    // A file another program holds keeps the filter in memory until the next change writes it.
    private void Write(Dictionary<string, SavedFilter> tables)
    {
        try
        {
            JsonFile.Write(_path, new TableFilterFile { Tables = tables }, ModelJson.Default.TableFilterFile);
        }
        catch (Exception exception) when (exception is IOException or UnauthorizedAccessException)
        {
        }
    }

    private sealed class Scope(TableFilterMemory memory, string connection, string? database) : ITableFilters
    {
        public TableFilter? Recall(TableName table) => memory.Recall(connection, database, table);

        public void Remember(TableName table, TableFilter? filter) => memory.Remember(connection, database, table, filter);
    }
}

// Per connection, database, schema and table, as macOS keys what it keeps of a table.
internal static class TableMemoryKey
{
    public static string Of(string connection, string? database, string? schema, string table) =>
        $"{Part(connection)}.{Part(database)}.{Part(schema)}.{Part(table)}";

    // Escaped dots included, which EscapeDataString leaves, so a dot in a name cannot make two tables one key.
    public static string Part(string? part) =>
        Uri.EscapeDataString(part ?? string.Empty).Replace(".", "%2E", StringComparison.Ordinal);
}
