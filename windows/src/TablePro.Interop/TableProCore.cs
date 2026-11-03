using Native = TablePro.Interop.Native;

namespace TablePro.Interop;

// ClientVersion goes to servers beside the app's name. A null StorageDirectory leaves the library and the drivers
// out. DriverSigners may sign a driver library; none refuses every driver.
public sealed record HostConfiguration(
    string ClientVersion,
    string? StorageDirectory = null,
    IReadOnlyList<DriverSigner>? DriverSigners = null);

// Subject is the signing certificate's, as X509Certificate2.Subject shows it. IssuerSha256 is the SHA-256 thumbprint
// of the certificate that issued it, the signer's own when it is self-signed.
public sealed record DriverSigner(string Subject, string IssuerSha256);

// Path is absolute. A null EngineId lets the file's first bytes decide, then its name. Create needs a new Path.
public sealed record FileOpenOptions(string Path, string? EngineId = null, bool ReadOnly = false, bool Create = false);

// The engines and the one runtime: an app makes one and keeps it.
public sealed class TableProCore : IDisposable
{
    private readonly Native.Core _core;
    private readonly Lazy<ConnectionLibrary> _library;
    private readonly Lazy<DriverPlugins> _drivers;

    private TableProCore(Native.Core core)
    {
        _core = core;
        Engines = [.. core.Drivers().Select(Mapping.Engine)];
        _library = new Lazy<ConnectionLibrary>(() => new ConnectionLibrary(CoreCall.Run(_core.Library)));
        _drivers = new Lazy<DriverPlugins>(() => new DriverPlugins(CoreCall.Run(_core.DriverPlugins)));
    }

    public IReadOnlyList<DatabaseEngine> Engines { get; }

    // Throws TableProException with code ffi.no_storage when the configuration named no storage directory.
    public ConnectionLibrary Library => _library.Value;

    // Throws TableProException with code ffi.no_storage when the configuration named no storage directory.
    public DriverPlugins Drivers => _drivers.Value;

    public static TableProCore Create(HostConfiguration configuration, ISecretStore secrets)
    {
        ArgumentNullException.ThrowIfNull(configuration);
        ArgumentNullException.ThrowIfNull(secrets);
        return new TableProCore(CoreCall.Run(() => new Native.Core(
            Mapping.Host(configuration),
            new SecretStoreAdapter(secrets))));
    }

    // Secrets stay in the platform's own store, which the core reaches itself: Credential Manager on Windows.
    public static TableProCore CreateWithSystemSecrets(HostConfiguration configuration)
    {
        ArgumentNullException.ThrowIfNull(configuration);
        return new TableProCore(CoreCall.Run(() => Native.Core.WithSystemSecrets(Mapping.Host(configuration))));
    }

    public static ParsedConnectionUrl ParseConnectionUrl(string url)
    {
        ArgumentNullException.ThrowIfNull(url);
        return Mapping.Url(CoreCall.Run(() => Native.CoreMethods.ParseConnectionUrl(url)));
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

    // Logs in with the secrets Credential Manager holds, or with the ones in secrets where those are set.
    public async Task<DatabaseSession> ConnectAsync(
        Guid connectionId,
        ConnectionSecrets? secrets = null,
        CancellationToken cancellationToken = default)
    {
        var typed = Mapping.Secrets(secrets ?? ConnectionSecrets.None);
        var session = await CoreCall.RunAsync(
                token => _core.ConnectSaved(connectionId.ToString(), typed, token),
                cancellationToken)
            .ConfigureAwait(false);
        return new DatabaseSession(session);
    }

    // Logs in with what a form holds, then closes the connection again.
    public Task TestConnectionAsync(
        SavedConnection connection,
        ConnectionSecrets secrets,
        CancellationToken cancellationToken = default)
    {
        ArgumentNullException.ThrowIfNull(connection);
        ArgumentNullException.ThrowIfNull(secrets);
        var record = Mapping.Record(connection);
        var typed = Mapping.Secrets(secrets);
        return CoreCall.RunAsync(token => _core.TestConnection(record, typed, token), cancellationToken);
    }

    public void Dispose()
    {
        if (_library.IsValueCreated)
        {
            _library.Value.Dispose();
        }

        if (_drivers.IsValueCreated)
        {
            _drivers.Value.Dispose();
        }

        _core.Dispose();
    }
}
