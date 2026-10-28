using TablePro.Core.Connections;
using TablePro.Core.Drivers;

namespace TablePro.Drivers.Dameng;

/// <summary>Dameng DM8 through the DM8 ODBC driver the Dameng client installs.</summary>
public sealed class DamengDriver : IDatabaseDriver
{
    public IReadOnlyList<DatabaseEngine> Engines { get; } = [DatabaseEngine.Dameng];

    public async Task<IDatabaseSession> ConnectAsync(ConnectionRequest request, CancellationToken cancellationToken)
    {
        var session = new DamengSession(request);
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
