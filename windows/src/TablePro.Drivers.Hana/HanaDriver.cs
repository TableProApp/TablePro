using TablePro.Core.Connections;
using TablePro.Core.Drivers;

namespace TablePro.Drivers.Hana;

/// <summary>SAP HANA through the HDBODBC driver the SAP HANA Client installs.</summary>
public sealed class HanaDriver : IDatabaseDriver
{
    public IReadOnlyList<DatabaseEngine> Engines { get; } = [DatabaseEngine.SapHana];

    public async Task<IDatabaseSession> ConnectAsync(ConnectionRequest request, CancellationToken cancellationToken)
    {
        var session = new HanaSession(request);
        try
        {
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
