using TablePro.Core.Connections;
using TablePro.Core.Drivers;

namespace TablePro.Drivers.Beancount;

/// <summary>
/// Beancount ledgers, read-only. Connecting runs Python Beancount or rledger over the ledger file named by the
/// profile and projects its directives into a private in-memory SQLite database with the macOS app's tables.
/// </summary>
public sealed class BeancountDriver : IDatabaseDriver
{
    private readonly IProcessRunner _runner;
    private readonly BeancountBackendLocator _locator;
    private readonly RledgerCapabilities _capabilities;

    public BeancountDriver()
        : this(SystemProcessRunner.Instance, null, RledgerCapabilities.Shared)
    {
    }

    internal BeancountDriver(IProcessRunner runner, BeancountBackendLocator? locator, RledgerCapabilities capabilities)
    {
        _runner = runner;
        _locator = locator ?? new BeancountBackendLocator(runner);
        _capabilities = capabilities;
    }

    public IReadOnlyList<DatabaseEngine> Engines { get; } = [DatabaseEngine.Beancount];

    public async Task<IDatabaseSession> ConnectAsync(ConnectionRequest request, CancellationToken cancellationToken)
    {
        await Task.CompletedTask.ConfigureAwait(ConfigureAwaitOptions.ForceYielding);
        var options = BeancountOptions.From(request);
        if (!File.Exists(options.LedgerPath))
        {
            throw BeancountException.ConnectionFailed("File does not exist at " + options.LedgerPath);
        }

        var projector = new BeancountProjector(options.LedgerPath, options.Timeout, ct => CreateSourceAsync(options, ct));
        var projection = await projector.BuildAsync(cancellationToken);
        return new BeancountSession(request, options, projector, _locator, _runner, _capabilities, projection);
    }

    private async Task<IBeancountProjectionSource> CreateSourceAsync(BeancountOptions options, CancellationToken cancellationToken)
    {
        var backend = await _locator.ProjectionBackendAsync(options, cancellationToken);
        return backend.Kind == BeancountBackendKind.Python
            ? new PythonBackend(backend, _runner, options.RunLedgerPlugins, _locator.PythonVersion(backend) ?? "Python Beancount")
            : new RledgerBackend(backend, _runner, _capabilities);
    }
}
