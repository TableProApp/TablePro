using TablePro.Core.Connections;
using TablePro.Core.Drivers;

namespace TablePro.Drivers.Oracle;

public sealed class OracleDriver : IDatabaseDriver
{
    public IReadOnlyList<DatabaseEngine> Engines { get; } = [DatabaseEngine.Oracle];

    public async Task<IDatabaseSession> ConnectAsync(ConnectionRequest request, CancellationToken cancellationToken)
    {
        var session = new OracleSession(request);
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
