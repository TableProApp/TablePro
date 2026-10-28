using TablePro.Core.Connections;
using TablePro.Core.Drivers;

namespace TablePro.Drivers.Redis;

/// <summary>Redis and servers that answer its protocol, such as Valkey, through StackExchange.Redis.</summary>
public sealed class RedisDriver : IDatabaseDriver
{
    public IReadOnlyList<DatabaseEngine> Engines { get; } = [DatabaseEngine.Redis];

    public async Task<IDatabaseSession> ConnectAsync(ConnectionRequest request, CancellationToken cancellationToken) =>
        await RedisSession.ConnectAsync(request, cancellationToken);
}
