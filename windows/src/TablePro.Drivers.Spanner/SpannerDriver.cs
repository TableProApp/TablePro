using TablePro.Core.Connections;
using TablePro.Core.Drivers;

namespace TablePro.Drivers.Spanner;

public sealed class SpannerDriver : IDatabaseDriver
{
    public IReadOnlyList<DatabaseEngine> Engines { get; } = [DatabaseEngine.Spanner];

    public async Task<IDatabaseSession> ConnectAsync(ConnectionRequest request, CancellationToken cancellationToken)
    {
        var session = new SpannerSession(request);
        try
        {
            await session.InitializeAsync(cancellationToken);
            await session.VerifyDialectAsync(cancellationToken);
            return session;
        }
        catch
        {
            await session.DisposeAsync();
            throw;
        }
    }
}
