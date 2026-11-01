using TablePro.Core.Connections;
using TablePro.Core.Drivers;

namespace TablePro.Drivers.DynamoDb;

public sealed class DynamoDbDriver : IDatabaseDriver
{
    public IReadOnlyList<DatabaseEngine> Engines { get; } = [DatabaseEngine.DynamoDb];

    public async Task<IDatabaseSession> ConnectAsync(ConnectionRequest request, CancellationToken cancellationToken) =>
        await DynamoDbSession.ConnectAsync(request, cancellationToken);
}
