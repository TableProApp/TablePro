using Native = TablePro.Interop.Native;

namespace TablePro.Interop;

// An editor tab's own connection. One statement runs at a time.
public sealed class QueryEditor : IAsyncDisposable
{
    private readonly Native.QueryEditor _editor;

    internal QueryEditor(Native.QueryEditor editor)
    {
        _editor = editor;
    }

    // Returns at once. The token stops the statement on the engine, and the run then ends Cancelled.
    public QueryRun Run(string sql, QueryOptions? options = null, CancellationToken cancellationToken = default)
    {
        ArgumentNullException.ThrowIfNull(sql);
        var settings = Mapping.Settings(options ?? new QueryOptions());
        var wake = new RunWake();
        return new QueryRun(_editor.Run(sql, settings, false, wake), wake, cancellationToken);
    }

    // An engine that binds a connection's database when it connects refuses it.
    public Task UseDatabaseAsync(string database, CancellationToken cancellationToken = default)
    {
        ArgumentException.ThrowIfNullOrEmpty(database);
        return CoreCall.RunAsync(token => _editor.UseDatabase(database, token), cancellationToken);
    }

    // The connection is gone, and is never opened again by itself since its transaction would not come back with it.
    public bool IsLost => _editor.IsLost();

    // Ends any transaction the connection holds.
    public async ValueTask DisposeAsync()
    {
        try
        {
            await CoreCall.RunAsync(() => _editor.Close()).ConfigureAwait(false);
        }
        finally
        {
            _editor.Dispose();
        }
    }
}
