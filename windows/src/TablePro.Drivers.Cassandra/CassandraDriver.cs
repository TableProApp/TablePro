using TablePro.Core.Connections;
using TablePro.Core.Drivers;

namespace TablePro.Drivers.Cassandra;

public sealed class CassandraDriver : IDatabaseDriver
{
    // ScyllaDB speaks the same native protocol and keeps the same system_schema tables.
    public IReadOnlyList<DatabaseEngine> Engines { get; } = [DatabaseEngine.Cassandra, DatabaseEngine.ScyllaDb];

    public async Task<IDatabaseSession> ConnectAsync(ConnectionRequest request, CancellationToken cancellationToken) =>
        await CassandraSession.ConnectAsync(request, cancellationToken);
}
