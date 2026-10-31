using TablePro.Core.Browse;
using TablePro.Core.Connections;
using TablePro.Core.Drivers;
using TablePro.Core.Editing;
using TablePro.Core.Results;
using TablePro.Core.Schema;
using TablePro.Core.Sql;

namespace TablePro.Core.Tests.Compare;

/// <summary>Several in-memory tables behind one session, each read and saved as <see cref="InMemoryTableSession"/> does.</summary>
internal sealed class InMemoryDatabaseSession(params InMemoryTableSession[] tables) : IDatabaseSession, IStorageEngineProvider
{
    private readonly Dictionary<string, InMemoryTableSession> _tables = tables.ToDictionary(t => t.Structure.Table.Name, StringComparer.OrdinalIgnoreCase);

    /// <summary>Every table each save named, in the order the saves ran.</summary>
    public List<string> SavedTables { get; } = [];

    /// <summary>A table whose saves throw, to stop a sync part way.</summary>
    public string? FailOnTable { get; set; }

    /// <summary>Each table's storage engine by name, as a MySQL catalog would answer; a table left out has none.</summary>
    public Dictionary<string, string> StorageEngines { get; } = new(StringComparer.OrdinalIgnoreCase);

    /// <summary>How many times the storage engines were read, to show a lookup is skipped when there is nothing to ask.</summary>
    public int StorageEngineReads { get; private set; }

    public ConnectionProfile Profile { get; } = new() { Name = "memory", Engine = DatabaseEngine.Sqlite };

    public SqlDialect Dialect => SqliteDialect.Instance;

    public string ServerVersion => "test";

    public string? CurrentDatabase => "main";

    public string? DefaultSchema => null;

    public InMemoryTableSession this[string table] => _tables[table];

    public Task<ResultSet> BrowseAsync(BrowseRequest request, CancellationToken cancellationToken) => Table(request.Table).BrowseAsync(request, cancellationToken);

    public Task<int> SaveChangesAsync(ObjectName table, IReadOnlyList<RowChange> changes, CancellationToken cancellationToken)
    {
        SavedTables.Add(table.Name);
        return string.Equals(table.Name, FailOnTable, StringComparison.OrdinalIgnoreCase)
            ? throw new InvalidOperationException("FOREIGN KEY constraint failed.")
            : Table(table).SaveChangesAsync(table, changes, cancellationToken);
    }

    public Task<TableStructure> GetStructureAsync(ObjectName table, CancellationToken cancellationToken) => Table(table).GetStructureAsync(table, cancellationToken);

    public Task<IReadOnlyList<DatabaseObject>> GetObjectsAsync(string? schema, CancellationToken cancellationToken) =>
        Task.FromResult<IReadOnlyList<DatabaseObject>>([.. _tables.Values.Select(t => new DatabaseObject(t.Structure.Table, ObjectKind.Table))]);

    public Task PingAsync(CancellationToken cancellationToken) => Task.CompletedTask;

    public Task<IReadOnlyList<string>> GetDatabasesAsync(CancellationToken cancellationToken) => Task.FromResult<IReadOnlyList<string>>(["main"]);

    public Task<IReadOnlyList<string>> GetSchemasAsync(CancellationToken cancellationToken) => Task.FromResult<IReadOnlyList<string>>([]);

    public Task<string> GetDefinitionAsync(DatabaseObject obj, CancellationToken cancellationToken) => Task.FromResult(string.Empty);

    public Task<long> CountAsync(ObjectName table, BrowseFilter filter, CancellationToken cancellationToken) => Table(table).CountAsync(table, filter, cancellationToken);

    public Task<IQueryChannel> OpenChannelAsync(CancellationToken cancellationToken) => throw new NotSupportedException();

    public ValueTask DisposeAsync() => ValueTask.CompletedTask;

    public Task<IReadOnlyDictionary<ObjectName, string>> GetStorageEnginesAsync(IReadOnlyCollection<ObjectName> tables, CancellationToken cancellationToken)
    {
        StorageEngineReads++;
        IReadOnlyDictionary<ObjectName, string> engines = tables
            .Where(t => StorageEngines.ContainsKey(t.Name))
            .ToDictionary(t => t, t => StorageEngines[t.Name]);
        return Task.FromResult(engines);
    }

    private InMemoryTableSession Table(ObjectName name) =>
        _tables.TryGetValue(name.Name, out var table) ? table : throw new InvalidOperationException($"no such table: {name.Name}");
}
