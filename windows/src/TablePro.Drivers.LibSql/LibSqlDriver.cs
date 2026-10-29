using TablePro.Core.Connections;
using TablePro.Core.Drivers;

namespace TablePro.Drivers.LibSql;

/// <summary>
/// libSQL and Turso. A remote database (a self-hosted sqld or Turso) is reached over the Hrana HTTP protocol. A local
/// database file is plain SQLite on disk, so it opens through the SQLite driver the app composes in; drivers reference
/// only Core, and that driver already has the catalog, the rebuilds and the structure editor a file needs.
/// </summary>
public sealed class LibSqlDriver : IDatabaseDriver
{
    private readonly IDatabaseDriver? _localFiles;
    private readonly Func<HttpMessageHandler>? _handlerFactory;

    /// <summary>Remote databases only, or with <paramref name="localFiles"/> the driver that opens a local SQLite file too.</summary>
    public LibSqlDriver(IDatabaseDriver? localFiles = null)
    {
        _localFiles = localFiles;
    }

    /// <summary>Tests hand in a fake handler so requests never leave the process.</summary>
    internal LibSqlDriver(Func<HttpMessageHandler> handlerFactory, IDatabaseDriver? localFiles = null)
    {
        _handlerFactory = handlerFactory;
        _localFiles = localFiles;
    }

    public IReadOnlyList<DatabaseEngine> Engines { get; } = [DatabaseEngine.LibSql, DatabaseEngine.Turso];

    public async Task<IDatabaseSession> ConnectAsync(ConnectionRequest request, CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(request);
        await Task.CompletedTask.ConfigureAwait(ConfigureAwaitOptions.ForceYielding);
        if (LibSqlSettings.LocalFile(request.Profile) is { } path)
        {
            var local = _localFiles ?? throw new LibSqlException("This build cannot open local libSQL files; connect to a server URL instead.");
            return await local.ConnectAsync(LocalRequest(request.Profile, path), cancellationToken);
        }

        return await LibSqlSession.ConnectAsync(request, _handlerFactory?.Invoke(), cancellationToken);
    }

    /// <summary>
    /// The profile as the SQLite driver reads it: the file in <see cref="ConnectionProfile.FilePath"/>, and only the
    /// options meant for the SQLite provider, which refuses keywords it does not know. Id, name and engine stay, so
    /// the workspace still belongs to this connection.
    /// </summary>
    internal static ConnectionRequest LocalRequest(ConnectionProfile profile, string path)
    {
        var options = profile.AdditionalOptions
            .Where(o => !LibSqlSettings.OwnOptions.Contains(o.Key))
            .ToDictionary(o => o.Key, o => o.Value, StringComparer.OrdinalIgnoreCase);
        var local = profile with { FilePath = Environment.ExpandEnvironmentVariables(path), AdditionalOptions = options };
        return new ConnectionRequest(local, null, local.Host, 0, null);
    }
}
