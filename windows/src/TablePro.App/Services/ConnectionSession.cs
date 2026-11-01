using System.Collections.Concurrent;
using TablePro.Core.Connections;
using TablePro.Core.Drivers;
using TablePro.Core.Schema;
using TablePro.Core.Sql;

namespace TablePro.App.Services;

/// <summary>
/// One open connection as the workspace sees it: the driver session, the tunnel it rides on, and the catalog the
/// sidebar and completion share. Structure is cached per table so reopening a tab costs no round trip.
/// </summary>
public sealed class ConnectionSession : IAsyncDisposable
{
    private readonly ConcurrentDictionary<ObjectName, TableStructure> _structures = new();
    private readonly IAsyncDisposable? _tunnel;
    private IReadOnlyList<DatabaseObject> _objects = [];
    private IReadOnlyList<string> _schemas = [];

    public ConnectionSession(IDatabaseSession database, IAsyncDisposable? tunnel)
    {
        Database = database;
        _tunnel = tunnel;
        CurrentSchema = database.DefaultSchema;
    }

    public event EventHandler? CatalogChanged;

    public IDatabaseSession Database { get; private set; }

    public ConnectionProfile Profile => Database.Profile;

    public SqlDialect Dialect => Database.Dialect;

    public string? CurrentSchema { get; set; }

    public IReadOnlyList<string> Schemas => _schemas;

    public IReadOnlyList<DatabaseObject> Objects => _objects;

    public CompletionCatalog Catalog { get; private set; } = CompletionCatalog.Empty;

    public async Task RefreshAsync(CancellationToken cancellationToken)
    {
        if (Profile.Descriptor.HasSchemas)
        {
            _schemas = await Database.GetSchemasAsync(cancellationToken);
            if (CurrentSchema is null || !_schemas.Contains(CurrentSchema))
            {
                CurrentSchema = Database.DefaultSchema is { } preferred && _schemas.Contains(preferred) ? preferred : _schemas.Count > 0 ? _schemas[0] : null;
            }
        }

        _objects = await Database.GetObjectsAsync(CurrentSchema, cancellationToken);
        _structures.Clear();
        RebuildCatalog();
    }

    public async Task<TableStructure> GetStructureAsync(ObjectName table, CancellationToken cancellationToken, bool refresh = false)
    {
        if (!refresh && _structures.TryGetValue(table, out var cached))
        {
            return cached;
        }

        var structure = await Database.GetStructureAsync(table, cancellationToken);
        _structures[table] = structure;
        RebuildCatalog();
        return structure;
    }

    /// <summary>Loads columns for the tables a statement names so completion can offer them after an alias.</summary>
    public async Task WarmColumnsAsync(IEnumerable<string> tableNames, CancellationToken cancellationToken)
    {
        foreach (var name in tableNames)
        {
            var match = _objects.FirstOrDefault(o => o.HasRows && string.Equals(o.Name.Name, name, StringComparison.OrdinalIgnoreCase));
            if (match is not null && !_structures.ContainsKey(match.Name))
            {
                try
                {
                    await GetStructureAsync(match.Name, cancellationToken);
                }
                catch (Exception ex) when (ex is not OperationCanceledException)
                {
                    // Completion is a convenience; a table it cannot describe just offers no columns.
                }
            }
        }
    }

    /// <summary>Switches database by reconnecting, since most engines bind a connection to one database.</summary>
    public async Task SwitchDatabaseAsync(IDatabaseDriver driver, ConnectionRequest request, CancellationToken cancellationToken)
    {
        var next = await driver.ConnectAsync(request, cancellationToken);
        var previous = Database;
        Database = next;
        CurrentSchema = next.DefaultSchema;
        await previous.DisposeAsync();
        await RefreshAsync(cancellationToken);
    }

    public async ValueTask DisposeAsync()
    {
        await Database.DisposeAsync();
        if (_tunnel is not null)
        {
            await _tunnel.DisposeAsync();
        }
    }

    private void RebuildCatalog()
    {
        var columns = new Dictionary<string, IReadOnlyList<(string Name, string Type)>>(StringComparer.OrdinalIgnoreCase);
        foreach (var (name, structure) in _structures)
        {
            var list = structure.Columns.Select(c => (c.Name, c.DataType)).ToArray();
            columns[name.Name] = list;
            columns[name.ToString()] = list;
        }

        Catalog = new CompletionCatalog(
            _schemas,
            _objects.Where(o => o.HasRows).Select(o => (o.Name.Name, o.Kind != ObjectKind.Table)).ToArray(),
            columns);
        CatalogChanged?.Invoke(this, EventArgs.Empty);
    }
}
