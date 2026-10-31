using System.Diagnostics;
using TablePro.Core.Browse;
using TablePro.Core.Connections;
using TablePro.Core.Drivers;
using TablePro.Core.Editing;
using TablePro.Core.Localization;
using TablePro.Core.Results;
using TablePro.Core.Schema;
using TablePro.Core.Sql;

namespace TablePro.Drivers.Beancount;

/// <summary>
/// A Beancount ledger, read through a SQLite projection of its directives. Before each call the session checks the
/// ledger and every file it includes; when one changed it rebuilds the projection, as the macOS app does on every
/// query. The ledger is never written: saves are refused and the editor runs only statements that read.
/// </summary>
internal sealed class BeancountSession : IDatabaseSession
{
    private readonly ConnectionRequest _request;
    private readonly BeancountOptions _options;
    private readonly BeancountProjector _projector;
    private readonly BeancountBackendLocator _locator;
    private readonly IProcessRunner _runner;
    private readonly RledgerCapabilities _capabilities;
    private readonly SemaphoreSlim _rebuildGate = new(1, 1);
    private readonly Lock _swapGate = new();
    private Build _current;
    private bool _disposed;

    public BeancountSession(
        ConnectionRequest request,
        BeancountOptions options,
        BeancountProjector projector,
        BeancountBackendLocator locator,
        IProcessRunner runner,
        RledgerCapabilities capabilities,
        BeancountProjection projection)
    {
        _request = request;
        _options = options;
        _projector = projector;
        _locator = locator;
        _runner = runner;
        _capabilities = capabilities;
        _current = new Build(projection, new BeancountSqlSession(request, projection.ConnectionString), 0);
    }

    public ConnectionProfile Profile => _request.Profile;

    public SqlDialect Dialect => BeancountDialect.Instance;

    public string ServerVersion => Volatile.Read(ref _current).Projection.BackendVersion;

    public string? CurrentDatabase => null;

    public string? DefaultSchema => null;

    public Task PingAsync(CancellationToken cancellationToken) => WithBuildAsync(static (sql, ct) => sql.PingAsync(ct), cancellationToken);

    public Task<IReadOnlyList<string>> GetDatabasesAsync(CancellationToken cancellationToken) => Task.FromResult<IReadOnlyList<string>>([]);

    public Task<IReadOnlyList<string>> GetSchemasAsync(CancellationToken cancellationToken) => Task.FromResult<IReadOnlyList<string>>([]);

    public Task<IReadOnlyList<DatabaseObject>> GetObjectsAsync(string? schema, CancellationToken cancellationToken) =>
        WithBuildAsync((sql, ct) => sql.GetObjectsAsync(schema, ct), cancellationToken);

    public Task<TableStructure> GetStructureAsync(ObjectName table, CancellationToken cancellationToken) =>
        WithBuildAsync((sql, ct) => sql.GetStructureAsync(table, ct), cancellationToken);

    public Task<string> GetDefinitionAsync(DatabaseObject obj, CancellationToken cancellationToken) =>
        WithBuildAsync((sql, ct) => sql.GetDefinitionAsync(obj, ct), cancellationToken);

    public Task<ResultSet> BrowseAsync(BrowseRequest request, CancellationToken cancellationToken) =>
        WithBuildAsync((sql, ct) => sql.BrowseAsync(request, ct), cancellationToken);

    public Task<long> CountAsync(ObjectName table, BrowseFilter filter, CancellationToken cancellationToken) =>
        WithBuildAsync((sql, ct) => sql.CountAsync(table, filter, ct), cancellationToken);

    public Task<int> SaveChangesAsync(ObjectName table, IReadOnlyList<RowChange> changes, CancellationToken cancellationToken) =>
        Task.FromException<int>(new NotSupportedException(BeancountException.ReadOnlyMessage));

    public Task<IQueryChannel> OpenChannelAsync(CancellationToken cancellationToken)
    {
        ObjectDisposedException.ThrowIf(_disposed, this);
        return Task.FromResult<IQueryChannel>(new BeancountQueryChannel(this));
    }

    public ValueTask DisposeAsync()
    {
        Build current;
        lock (_swapGate)
        {
            if (_disposed)
            {
                return ValueTask.CompletedTask;
            }

            _disposed = true;
            current = _current;
        }

        current.Projection.Retire();
        return ValueTask.CompletedTask;
    }

    /// <summary>Rebuilds the projection when the ledger changed since the current one was read.</summary>
    internal async Task RefreshIfChangedAsync(CancellationToken cancellationToken)
    {
        await Task.CompletedTask.ConfigureAwait(ConfigureAwaitOptions.ForceYielding);
        ObjectDisposedException.ThrowIf(_disposed, this);
        if (!Volatile.Read(ref _current).Projection.IsStale())
        {
            return;
        }

        await _rebuildGate.WaitAsync(cancellationToken);
        try
        {
            var stale = Volatile.Read(ref _current);

            // Another caller may have rebuilt while this one waited for the gate.
            if (!stale.Projection.IsStale())
            {
                return;
            }

            var projection = await _projector.BuildAsync(cancellationToken);
            var next = new Build(projection, new BeancountSqlSession(_request, projection.ConnectionString), stale.Generation + 1);
            lock (_swapGate)
            {
                if (_disposed)
                {
                    projection.Retire();
                    throw new ObjectDisposedException(nameof(BeancountSession));
                }

                _current = next;
            }

            stale.Projection.Retire();
        }
        finally
        {
            _rebuildGate.Release();
        }
    }

    /// <summary>
    /// The current projection's session with a lease on its database, refreshed first. The caller releases the lease
    /// once its connection is open or its call is done.
    /// </summary>
    internal async Task<(BeancountSqlSession Sql, BeancountProjection Projection, int Generation)> AcquireAsync(CancellationToken cancellationToken)
    {
        await RefreshIfChangedAsync(cancellationToken);
        lock (_swapGate)
        {
            ObjectDisposedException.ThrowIf(_disposed, this);
            _current.Projection.AddLease();
            return (_current.Sql, _current.Projection, _current.Generation);
        }
    }

    /// <summary>Runs one <c>BQL:</c> statement through rledger against the ledger file itself.</summary>
    internal async Task<StatementResult> RunBqlAsync(string statement, string bql, ExecuteOptions options, CancellationToken cancellationToken)
    {
        await Task.CompletedTask.ConfigureAwait(ConfigureAwaitOptions.ForceYielding);
        var stopwatch = Stopwatch.StartNew();
        using var timeout = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
        if (options.CommandTimeoutSeconds > 0)
        {
            timeout.CancelAfter(TimeSpan.FromSeconds(options.CommandTimeoutSeconds));
        }

        try
        {
            var rledger = new RledgerBackend(_locator.QueryBackend(_options), _runner, _capabilities);
            var json = await rledger.QueryJsonAsync(_options.LedgerPath, bql, timeout.Token);
            return new StatementResult(statement, [RledgerOutput.QueryResult(json, options.RowLimit)], 0, stopwatch.Elapsed);
        }
        catch (OperationCanceledException)
        {
            return new StatementResult(statement, [], -1, stopwatch.Elapsed, CoreStrings.Get(cancellationToken.IsCancellationRequested ? "Driver/QueryCancelled" : "Driver/QueryTimedOut"));
        }
        catch (BeancountException ex)
        {
            return new StatementResult(statement, [], -1, stopwatch.Elapsed, ex.Message);
        }
    }

    private async Task<T> WithBuildAsync<T>(Func<BeancountSqlSession, CancellationToken, Task<T>> work, CancellationToken cancellationToken)
    {
        var (sql, projection, _) = await AcquireAsync(cancellationToken);
        try
        {
            return await work(sql, cancellationToken);
        }
        finally
        {
            projection.ReleaseLease();
        }
    }

    private async Task WithBuildAsync(Func<BeancountSqlSession, CancellationToken, Task> work, CancellationToken cancellationToken) =>
        await WithBuildAsync(
            async (sql, ct) =>
            {
                await work(sql, ct);
                return true;
            },
            cancellationToken);

    private sealed record Build(BeancountProjection Projection, BeancountSqlSession Sql, int Generation);
}
