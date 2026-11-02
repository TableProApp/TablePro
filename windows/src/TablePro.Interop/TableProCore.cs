using Native = TablePro.Interop.Native;

namespace TablePro.Interop;

/// <param name="ClientVersion">Reported to servers next to the application name.</param>
public sealed record HostConfiguration(string ClientVersion);

/// <param name="Path">An absolute path.</param>
/// <param name="EngineId">The engine to open it with. Null lets the file's first bytes decide, then its name.</param>
/// <param name="Create">Make a new database at <paramref name="Path"/>, which must not exist yet.</param>
public sealed record FileOpenOptions(string Path, string? EngineId = null, bool ReadOnly = false, bool Create = false);

/// <summary>The shared core: its engines and its one runtime. An app makes one and keeps it.</summary>
public sealed class TableProCore : IDisposable
{
    private readonly Native.Core _core;

    private TableProCore(Native.Core core)
    {
        _core = core;
        Engines = [.. core.Drivers().Select(Mapping.Engine)];
    }

    public IReadOnlyList<DatabaseEngine> Engines { get; }

    public static TableProCore Create(HostConfiguration configuration, ISecretStore secrets)
    {
        ArgumentNullException.ThrowIfNull(configuration);
        ArgumentNullException.ThrowIfNull(secrets);
        return new TableProCore(CoreCall.Run(() => new Native.Core(
            new Native.HostConfig(configuration.ClientVersion),
            new SecretStoreAdapter(secrets))));
    }

    public async Task<DatabaseSession> OpenFileAsync(
        FileOpenOptions options,
        CancellationToken cancellationToken = default)
    {
        ArgumentNullException.ThrowIfNull(options);
        var request = new Native.FileOpenRequest(options.Path, options.EngineId, options.ReadOnly, options.Create);
        var session = await CoreCall.RunAsync(token => _core.OpenFile(request, token), cancellationToken)
            .ConfigureAwait(false);
        return new DatabaseSession(session);
    }

    public void Dispose() => _core.Dispose();
}
