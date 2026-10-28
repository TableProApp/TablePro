using TablePro.Core.Connections;
using TablePro.Core.Drivers;

namespace TablePro.Drivers.SqlServer;

public sealed class SqlServerDriver : IDatabaseDriver
{
    public IReadOnlyList<DatabaseEngine> Engines { get; } = [DatabaseEngine.SqlServer];

    public async Task<IDatabaseSession> ConnectAsync(ConnectionRequest request, CancellationToken cancellationToken)
    {
        var session = new SqlServerSession(request);
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
