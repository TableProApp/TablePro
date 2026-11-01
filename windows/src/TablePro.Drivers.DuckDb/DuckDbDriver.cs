using TablePro.Core.Connections;
using TablePro.Core.Drivers;

namespace TablePro.Drivers.DuckDb;

public sealed class DuckDbDriver : IDatabaseDriver
{
    public IReadOnlyList<DatabaseEngine> Engines { get; } = [DatabaseEngine.DuckDb];

    public async Task<IDatabaseSession> ConnectAsync(ConnectionRequest request, CancellationToken cancellationToken)
    {
        var session = new DuckDbSession(request);
        try
        {
            await session.InitializeAsync(cancellationToken);
            await session.StartAsync(cancellationToken);
            return session;
        }
        catch
        {
            await session.DisposeAsync();
            throw;
        }
    }
}
