using Native = TablePro.Interop.Native;

namespace TablePro.Interop;

/// <summary>An editor tab's own connection. One statement runs at a time.</summary>
public sealed class QueryEditor : IAsyncDisposable
{
    private readonly Native.QueryEditor _editor;

    internal QueryEditor(Native.QueryEditor editor)
    {
        _editor = editor;
    }

    /// <summary>
    /// Starts <paramref name="sql"/> on the core's runtime and returns at once. <paramref name="cancellationToken"/>
    /// stops the statement on the engine, and the run then ends <see cref="QueryOutcome.Cancelled"/>.
    /// </summary>
    public QueryRun Run(string sql, QueryOptions? options = null, CancellationToken cancellationToken = default)
    {
        ArgumentNullException.ThrowIfNull(sql);
        var settings = Mapping.Settings(options ?? new QueryOptions());
        var wake = new RunWake();
        return new QueryRun(_editor.Run(sql, settings, wake), wake, cancellationToken);
    }

    // The connection is gone, and is never opened again by itself since its transaction would not come back with it.
    public bool IsLost => _editor.IsLost();

    /// <summary>Closes the editor's connection, which ends any transaction it holds.</summary>
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
