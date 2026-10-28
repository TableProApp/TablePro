using TablePro.Core.Connections;
using TablePro.Core.Drivers;

namespace TablePro.Drivers.MySql;

public sealed class MySqlDriver : IDatabaseDriver
{
    public IReadOnlyList<DatabaseEngine> Engines { get; } = [DatabaseEngine.MySql, DatabaseEngine.MariaDb];

    public async Task<IDatabaseSession> ConnectAsync(ConnectionRequest request, CancellationToken cancellationToken)
    {
        var session = new MySqlSession(request);
        try
        {
            await session.InitializeAsync(cancellationToken);
            return session;
        }
        catch
        {
            await session.DisposeAsync();
            throw;
        }
    }
}
