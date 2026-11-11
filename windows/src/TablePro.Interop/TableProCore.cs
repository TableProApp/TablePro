using Native = TablePro.Interop.Native;

namespace TablePro.Interop;

// ClientVersion goes to servers beside the app's name. A null StorageDirectory leaves the library out.
public sealed record HostConfiguration(string ClientVersion, string? StorageDirectory = null);

// Path is absolute. A null EngineId lets the file's first bytes decide, then its name. Create needs a new Path.
public sealed record FileOpenOptions(string Path, string? EngineId = null, bool ReadOnly = false, bool Create = false);

// The engines and the one runtime: an app makes one and keeps it.
public sealed class TableProCore : IDisposable
{
    private readonly Native.Core _core;
    private readonly Lazy<ConnectionLibrary> _library;

    private TableProCore(Native.Core core)
    {
        _core = core;
        Engines = [.. core.Drivers().Select(Mapping.Engine)];
        _library = new Lazy<ConnectionLibrary>(() => new ConnectionLibrary(CoreCall.Run(_core.Library)));
    }

    public IReadOnlyList<DatabaseEngine> Engines { get; }

    // Throws TableProException with code ffi.no_storage when the configuration named no storage directory.
    public ConnectionLibrary Library => _library.Value;

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

    // Logs in with secrets where set, else Credential Manager's; the core stores keep once it has logged in.
    public async Task<DatabaseSession> ConnectAsync(
        Guid connectionId,
        ConnectionSecrets? secrets = null,
        ICredentialPrompter? prompter = null,
        ConnectionSecrets? keep = null,
        CancellationToken cancellationToken = default)
    {
        var typed = Mapping.Secrets(secrets ?? ConnectionSecrets.None);
        var kept = Mapping.Secrets(keep ?? ConnectionSecrets.None);
        var adapter = prompter is null ? null : new CredentialPrompterAdapter(prompter);
        using var registration = cancellationToken.Register(() => adapter?.Cancel());
        try
        {
            var session = await CoreCall.RunAsync(
                    token => _core.ConnectSaved(connectionId.ToString(), typed, kept, adapter, token),
                    cancellationToken)
                .ConfigureAwait(false);
            return new DatabaseSession(session, adapter);
        }
        catch
        {
            adapter?.Dispose();
            throw;
        }
    }

    // Logs in with what a form holds, then closes the connection again.
    public async Task TestConnectionAsync(
        SavedConnection connection,
        ConnectionSecrets secrets,
        ICredentialPrompter? prompter = null,
        CancellationToken cancellationToken = default)
    {
        ArgumentNullException.ThrowIfNull(connection);
        ArgumentNullException.ThrowIfNull(secrets);
        var record = Mapping.Record(connection);
        var typed = Mapping.Secrets(secrets);
        using var adapter = prompter is null ? null : new CredentialPrompterAdapter(prompter);
        using var registration = cancellationToken.Register(() => adapter?.Cancel());
        await CoreCall.RunAsync(token => _core.TestConnection(record, typed, adapter, token), cancellationToken)
            .ConfigureAwait(false);
    }

    public Task ForgetChangedHostKeyAsync(SavedConnection connection, HostKeyFailure failure)
    {
        ArgumentNullException.ThrowIfNull(connection);
        ArgumentNullException.ThrowIfNull(failure);
        if (!failure.TrustAllowed)
        {
            throw new ArgumentException("This SSH key cannot be replaced.", nameof(failure));
        }

        return CoreCall.RunAsync(() => _core.ForgetChangedHostKey(
            Mapping.Record(connection), failure.Host, failure.KnownHosts));
    }

    public void Dispose()
    {
        if (_library.IsValueCreated)
        {
            _library.Value.Dispose();
        }

        _core.Dispose();
    }
}
