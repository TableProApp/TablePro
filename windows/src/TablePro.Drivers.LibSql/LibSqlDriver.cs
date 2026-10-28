using TablePro.Core.Connections;
using TablePro.Core.Drivers;

namespace TablePro.Drivers.LibSql;

/// <summary>Remote libSQL: a self-hosted sqld or a Turso database, over the Hrana HTTP protocol.</summary>
public sealed class LibSqlDriver : IDatabaseDriver
{
    private readonly Func<HttpMessageHandler>? _handlerFactory;

    public LibSqlDriver()
    {
    }

    /// <summary>Tests hand in a fake handler so requests never leave the process.</summary>
    internal LibSqlDriver(Func<HttpMessageHandler> handlerFactory)
    {
        _handlerFactory = handlerFactory;
    }

    public IReadOnlyList<DatabaseEngine> Engines { get; } = [DatabaseEngine.LibSql, DatabaseEngine.Turso];

    public async Task<IDatabaseSession> ConnectAsync(ConnectionRequest request, CancellationToken cancellationToken)
    {
        await Task.CompletedTask.ConfigureAwait(ConfigureAwaitOptions.ForceYielding);
        return await LibSqlSession.ConnectAsync(request, _handlerFactory?.Invoke(), cancellationToken);
    }
}
