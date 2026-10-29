using TablePro.Core.Connections;
using TablePro.Core.Drivers;
using TablePro.Ssh.Localization;

namespace TablePro.Ssh;

/// <summary>The secrets the transports keep in the credential vault, read just before connecting.</summary>
public sealed record NetworkTunnelSecrets
{
    public string? ProxyPassword { get; init; }
    public string? CloudSqlServiceAccountKey { get; init; }
    public string? CloudflareTokenId { get; init; }
    public string? CloudflareTokenSecret { get; init; }
}

public sealed record NetworkTunnelOptions
{
    /// <summary>The longest wait for a helper's port to open, on top of the profile's connect timeout.</summary>
    public TimeSpan ReadyTimeout { get; init; } = TimeSpan.FromSeconds(20);

    /// <summary>Fresh ports to try when another program takes an automatic one first, as the macOS app does.</summary>
    public int PortAttempts { get; init; } = 5;

    /// <summary>Overrides the PATH lookup of helper programs, for tests.</summary>
    public string? SearchPath { get; init; }
}

public interface INetworkTunnelFactory
{
    /// <summary>
    /// Opens the profile's proxy, Cloud SQL Auth Proxy, Cloudflare tunnel or tunnel command. SSH tunnels have their own
    /// factory; a profile with no such transport is an argument error.
    /// </summary>
    Task<IConnectionTunnel> OpenAsync(ConnectionRequest request, NetworkTunnelSecrets secrets, CancellationToken cancellationToken);
}

/// <summary>Starts the transports other than SSH and rewrites the request to their loopback end, as the SSH factory does.</summary>
public sealed class NetworkTunnelFactory(NetworkTunnelOptions? options = null) : INetworkTunnelFactory
{
    private readonly NetworkTunnelOptions _options = options ?? new NetworkTunnelOptions();

    public static bool Handles(ConnectionTransport transport) =>
        transport is ConnectionTransport.Proxy or ConnectionTransport.CloudSqlProxy or ConnectionTransport.CloudflareTunnel or ConnectionTransport.TunnelCommand;

    public async Task<IConnectionTunnel> OpenAsync(ConnectionRequest request, NetworkTunnelSecrets secrets, CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(request);
        ArgumentNullException.ThrowIfNull(secrets);
        var profile = request.Profile;
        if (profile.Validate() is { } problem)
        {
            throw new TunnelException(TunnelFailureKind.InvalidSettings, problem);
        }

        var connectTimeout = TimeSpan.FromSeconds(Math.Max(1, profile.ConnectTimeoutSeconds));
        var readyTimeout = connectTimeout + _options.ReadyTimeout;
        switch (profile.ActiveTransport())
        {
            case ConnectionTransport.Proxy:
                return await ProxyForwarder.StartAsync(request, profile.Proxy!, secrets.ProxyPassword, connectTimeout, cancellationToken);

            case ConnectionTransport.CloudSqlProxy:
            {
                var settings = profile.CloudSqlProxy!;
                var executable = Locate(settings.ExecutablePath, HelperArguments.CloudSqlProxyName, ExecutableLocator.GoogleCloudSdkDirectories(), SshStrings.Get("Tunnel/CloudSqlProxyNotFound"));
                var environment = HelperArguments.CloudSqlProxyEnvironment(settings, secrets.CloudSqlServiceAccountKey);
                return await StartHelperAsync(
                    request,
                    new LocalPortPolicy(settings.LocalPort, _options.PortAttempts),
                    port => new HelperLaunch(SshStrings.Get("Tunnel/CloudSqlProxyName"), executable, HelperArguments.CloudSqlProxy(settings, port), environment),
                    readyTimeout,
                    inspect: null,
                    cancellationToken);
            }

            case ConnectionTransport.CloudflareTunnel:
            {
                var settings = profile.CloudflareTunnel!;
                var executable = Locate(settings.ExecutablePath, HelperArguments.CloudflaredName, ExecutableLocator.CloudflaredDirectories(), SshStrings.Get("Tunnel/CloudflaredNotFound"));
                var environment = HelperArguments.CloudflaredEnvironment(settings, secrets.CloudflareTokenId, secrets.CloudflareTokenSecret);
                return await StartHelperAsync(
                    request,
                    new LocalPortPolicy(settings.LocalPort, _options.PortAttempts),
                    port => new HelperLaunch("cloudflared", executable, HelperArguments.Cloudflared(settings, port), environment),
                    readyTimeout,
                    CloudflaredSignInRequired,
                    cancellationToken);
            }

            case ConnectionTransport.TunnelCommand:
            {
                var settings = profile.TunnelCommand!;
                return await StartHelperAsync(
                    request,
                    new LocalPortPolicy(null, _options.PortAttempts),
                    port =>
                    {
                        var invocation = TunnelCommandLine.Build(settings, port, request.Host, request.Port);
                        var executable = Locate(invocation.Executable, invocation.Executable, ExecutableLocator.PackageManagerDirectories(), SshStrings.Format("Tunnel/CommandNotFound", invocation.Executable));
                        return new HelperLaunch(SshStrings.Get("Tunnel/TunnelCommandName"), executable, invocation.Arguments, new Dictionary<string, string>());
                    },
                    readyTimeout,
                    inspect: null,
                    cancellationToken);
            }

            default:
                throw new ArgumentException(SshStrings.Get("Tunnel/NotAProxyOrHelper"), nameof(request));
        }
    }

    private static TunnelException? CloudflaredSignInRequired(string output) =>
        HelperArguments.CloudflaredSignInUri(output) is { } uri
            ? new TunnelException(TunnelFailureKind.BrowserSignInRequired, SshStrings.Format("Tunnel/CloudflareSignIn", uri), output) { SignInUri = uri }
            : null;

    private static async Task<IConnectionTunnel> StartHelperAsync(
        ConnectionRequest request,
        LocalPortPolicy ports,
        Func<int, HelperLaunch> launch,
        TimeSpan readyTimeout,
        Func<string, TunnelException?>? inspect,
        CancellationToken cancellationToken)
    {
        for (var attempt = 1; ; attempt++)
        {
            var port = ports.PortFor(attempt);

            // A fixed port another program already answers on would have the driver talk to that program.
            if (!ports.IsAutomatic && await FreePort.AcceptsConnectionsAsync(port, TimeSpan.FromMilliseconds(300), cancellationToken))
            {
                throw new TunnelException(TunnelFailureKind.LocalPortUnavailable, SshStrings.Format("Tunnel/FixedPortInUse", port));
            }

            if (ports.IsAutomatic && await FreePort.AcceptsConnectionsAsync(port, TimeSpan.FromMilliseconds(300), cancellationToken))
            {
                if (ports.RetriesAfter(attempt))
                {
                    continue;
                }

                throw new TunnelException(TunnelFailureKind.LocalPortUnavailable, SshStrings.Get("Tunnel/NoFreePort"));
            }

            var tunneled = TunneledRequest(request, port);
            try
            {
                return await ProcessTunnel.StartAsync(launch(port), port, tunneled, readyTimeout, inspect, cancellationToken);
            }
            catch (TunnelException ex) when (ex.Kind == TunnelFailureKind.LocalPortUnavailable && ports.RetriesAfter(attempt))
            {
            }
            catch (FormatException ex)
            {
                throw new TunnelException(TunnelFailureKind.InvalidSettings, ex.Message, innerException: ex);
            }
        }
    }

    private static ConnectionRequest TunneledRequest(ConnectionRequest request, int port) =>
        request with { Host = SshArguments.LoopbackAddress, Port = port };

    private string Locate(string? configuredPath, string name, IEnumerable<string> extraDirectories, string notFound)
    {
        var lookup = string.IsNullOrWhiteSpace(configuredPath) ? name : configuredPath;
        return ExecutableLocator.Find(lookup, extraDirectories, _options.SearchPath)
            ?? throw new TunnelException(TunnelFailureKind.ExecutableNotFound, notFound);
    }
}
