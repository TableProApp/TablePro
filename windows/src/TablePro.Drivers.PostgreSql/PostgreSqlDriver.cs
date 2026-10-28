using TablePro.Core.Connections;
using TablePro.Core.Drivers;

namespace TablePro.Drivers.PostgreSql;

public sealed class PostgreSqlDriver : IDatabaseDriver
{
    public IReadOnlyList<DatabaseEngine> Engines { get; } = [DatabaseEngine.PostgreSql];

    public async Task<IDatabaseSession> ConnectAsync(ConnectionRequest request, CancellationToken cancellationToken)
    {
        var session = new PostgreSqlSession(request);
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
