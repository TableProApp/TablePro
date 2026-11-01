using TablePro.Core.Connections;
using TablePro.Core.Drivers;

namespace TablePro.Drivers.PostgreSql;

public sealed class PostgreSqlDriver : IDatabaseDriver
{
    // CockroachDB, Redshift and PGlite speak the PostgreSQL wire protocol and keep enough of its catalog to browse.
    public IReadOnlyList<DatabaseEngine> Engines { get; } = [DatabaseEngine.PostgreSql, DatabaseEngine.CockroachDb, DatabaseEngine.Redshift, DatabaseEngine.PGlite];

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
