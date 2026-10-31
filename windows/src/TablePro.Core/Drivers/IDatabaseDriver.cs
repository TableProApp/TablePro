using TablePro.Core.Browse;
using TablePro.Core.Connections;
using TablePro.Core.Editing;
using TablePro.Core.Localization;
using TablePro.Core.Results;
using TablePro.Core.Schema;
using TablePro.Core.Sql;

namespace TablePro.Core.Drivers;

/// <summary>
/// What a driver needs to open a session. <see cref="Host"/> and <see cref="Port"/> are where to dial, which an SSH
/// tunnel replaces with its local end; the profile keeps what the user typed.
/// </summary>
public sealed record ConnectionRequest(ConnectionProfile Profile, string? Password, string Host, int Port, string? Database)
{
    public static ConnectionRequest Direct(ConnectionProfile profile, string? password) =>
        new(profile, password, profile.Host, profile.EffectivePort, profile.Database);
}

/// <summary>One engine family. Drivers are registered once at startup in the app's composition root.</summary>
public interface IDatabaseDriver
{
    IReadOnlyList<DatabaseEngine> Engines { get; }

    Task<IDatabaseSession> ConnectAsync(ConnectionRequest request, CancellationToken cancellationToken);
}

/// <summary>
/// A connected database. It serves the sidebar, table tabs and saves from pooled connections, and hands each editor
/// tab a <see cref="IQueryChannel"/> of its own so session state (transactions, SET, temp tables) stays with the tab.
/// </summary>
public interface IDatabaseSession : IAsyncDisposable
{
    ConnectionProfile Profile { get; }

    SqlDialect Dialect { get; }

    string ServerVersion { get; }

    string? CurrentDatabase { get; }

    /// <summary>The schema the sidebar opens on, such as <c>public</c> or <c>dbo</c>.</summary>
    string? DefaultSchema { get; }

    Task PingAsync(CancellationToken cancellationToken);

    Task<IReadOnlyList<string>> GetDatabasesAsync(CancellationToken cancellationToken);

    Task<IReadOnlyList<string>> GetSchemasAsync(CancellationToken cancellationToken);

    Task<IReadOnlyList<DatabaseObject>> GetObjectsAsync(string? schema, CancellationToken cancellationToken);

    Task<TableStructure> GetStructureAsync(ObjectName table, CancellationToken cancellationToken);

    /// <summary>The CREATE statement for a table, view or routine.</summary>
    Task<string> GetDefinitionAsync(DatabaseObject obj, CancellationToken cancellationToken);

    Task<ResultSet> BrowseAsync(BrowseRequest request, CancellationToken cancellationToken);

    Task<long> CountAsync(ObjectName table, BrowseFilter filter, CancellationToken cancellationToken);

    /// <summary>Applies every change in one transaction, rolling all of them back when one touches the wrong number of rows.</summary>
    Task<int> SaveChangesAsync(ObjectName table, IReadOnlyList<RowChange> changes, CancellationToken cancellationToken);

    Task<IQueryChannel> OpenChannelAsync(CancellationToken cancellationToken);
}

/// <summary>A dedicated connection for one editor tab.</summary>
public interface IQueryChannel : IAsyncDisposable
{
    /// <summary>Runs the statements in order, yielding each one's result as soon as it is read.</summary>
    IAsyncEnumerable<StatementResult> ExecuteAsync(IReadOnlyList<string> statements, ExecuteOptions options, CancellationToken cancellationToken);
}

public sealed class DriverRegistry
{
    private readonly Dictionary<DatabaseEngine, IDatabaseDriver> _drivers = [];

    public DriverRegistry Register(IDatabaseDriver driver)
    {
        foreach (var engine in driver.Engines)
        {
            _drivers[engine] = driver;
        }

        return this;
    }

    public bool Supports(DatabaseEngine engine) => _drivers.ContainsKey(engine);

    public IDatabaseDriver Resolve(DatabaseEngine engine) =>
        _drivers.TryGetValue(engine, out var driver)
            ? driver
            : throw new NotSupportedException(CoreStrings.Format("Data/NoDriver", EngineDescriptor.For(engine).DisplayName));
}
