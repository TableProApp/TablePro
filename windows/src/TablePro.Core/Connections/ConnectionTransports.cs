using TablePro.Core.Localization;

namespace TablePro.Core.Connections;

/// <summary>
/// How the app reaches the server. The macOS app derives the same choice from which transport is enabled
/// (<c>ConnectionTunnelKind</c>); a profile turns on at most one.
/// </summary>
public enum ConnectionTransport
{
    Direct,
    Ssh,

    /// <summary>A SOCKS5 or HTTP CONNECT proxy, reached through a loopback forwarder.</summary>
    Proxy,
    CloudSqlProxy,
    CloudflareTunnel,
    TunnelCommand,
}

public enum ProxyProtocol
{
    /// <summary>RFC 1928, with RFC 1929 user and password when a user is set. The proxy resolves the database host.</summary>
    Socks5,

    /// <summary>An HTTP proxy that tunnels with <c>CONNECT</c>, for networks that offer no SOCKS proxy.</summary>
    HttpConnect,
}

/// <summary>A proxy every database connection goes through. The password is kept by the credential vault.</summary>
public sealed record ProxySettings
{
    public bool Enabled { get; init; }
    public ProxyProtocol Protocol { get; init; } = ProxyProtocol.Socks5;
    public string Host { get; init; } = string.Empty;
    public int Port { get; init; } = 1080;

    /// <summary>Empty connects without authentication.</summary>
    public string? Username { get; init; }
}

/// <summary>Same raw meaning as the macOS <c>CloudSQLProxyAuthMode</c>.</summary>
public enum CloudSqlAuthMode
{
    /// <summary>gcloud's application default credentials, or the file GOOGLE_APPLICATION_CREDENTIALS names.</summary>
    ApplicationDefault,

    /// <summary>A service account key JSON the credential vault holds, handed to the proxy as a temporary file.</summary>
    ServiceAccountKey,
}

/// <summary>Runs Google's <c>cloud-sql-proxy</c> on a loopback port and connects through it.</summary>
public sealed record CloudSqlProxySettings
{
    public bool Enabled { get; init; }

    /// <summary><c>project:region:instance</c>, from the instance's overview page.</summary>
    public string InstanceConnectionName { get; init; } = string.Empty;

    public CloudSqlAuthMode AuthMode { get; init; } = CloudSqlAuthMode.ApplicationDefault;

    /// <summary>Passes <c>--auto-iam-authn</c>: the user name is the IAM principal and the password is unused.</summary>
    public bool UseIamAuth { get; init; }

    public bool UsePrivateIp { get; init; }

    /// <summary>Null picks a free port each time.</summary>
    public int? LocalPort { get; init; }

    /// <summary>Null finds <c>cloud-sql-proxy.exe</c> on PATH or in the Google Cloud SDK.</summary>
    public string? ExecutablePath { get; init; }
}

/// <summary>Same raw meaning as the macOS <c>CloudflareAuthMethod</c>.</summary>
public enum CloudflareAuthMethod
{
    /// <summary>cloudflared's own browser sign-in, cached by <c>cloudflared access login</c>.</summary>
    BrowserSso,

    /// <summary>A service token whose client id and secret the credential vault holds.</summary>
    ServiceToken,
}

/// <summary>Runs <c>cloudflared access tcp</c> against a Cloudflare Access application.</summary>
public sealed record CloudflareTunnelSettings
{
    public bool Enabled { get; init; }

    /// <summary>The Access application's host name, such as <c>db.example.com</c>.</summary>
    public string AccessHostname { get; init; } = string.Empty;

    public int? LocalPort { get; init; }
    public CloudflareAuthMethod AuthMethod { get; init; } = CloudflareAuthMethod.BrowserSso;

    /// <summary>Listens on every interface instead of loopback only.</summary>
    public bool ExposeToLan { get; init; }

    public string? ExecutablePath { get; init; }
}

/// <summary>Same raw values as the macOS <c>TunnelCommandMethod</c>.</summary>
public enum TunnelCommandMethod
{
    /// <summary><c>kubectl port-forward</c> to a resource.</summary>
    Kubectl,

    /// <summary>An AWS Systems Manager port-forwarding session.</summary>
    AwsSsm,

    /// <summary>Any command that forwards the local port the app chose, written with placeholders.</summary>
    Custom,
}

/// <summary>A program the app starts to forward a local port, such as <c>kubectl port-forward</c>.</summary>
public sealed record TunnelCommandSettings
{
    public bool Enabled { get; init; }
    public TunnelCommandMethod Method { get; init; } = TunnelCommandMethod.Kubectl;

    /// <summary>The custom command line. See <see cref="TunnelCommandLine"/> for the placeholders and quoting.</summary>
    public string? Command { get; init; }

    /// <summary>The kubectl or aws executable for the presets. Null finds it on PATH.</summary>
    public string? ExecutablePath { get; init; }

    public string? KubernetesNamespace { get; init; }
    public string? KubernetesResource { get; init; }
    public string? KubernetesContext { get; init; }
    public string? AwsTarget { get; init; }
    public string? AwsProfile { get; init; }
    public string? AwsRegion { get; init; }
}

/// <summary>What the form and the connect path ask of a profile's transports.</summary>
public static class ConnectionTransports
{
    public static string DisplayName(this ConnectionTransport transport) => transport switch
    {
        ConnectionTransport.Ssh => CoreStrings.Get("Connection/TransportSsh"),
        ConnectionTransport.Proxy => CoreStrings.Get("Connection/TransportProxy"),
        ConnectionTransport.CloudSqlProxy => CoreStrings.Get("Connection/TransportCloudSql"),
        ConnectionTransport.CloudflareTunnel => CoreStrings.Get("Connection/TransportCloudflare"),
        ConnectionTransport.TunnelCommand => CoreStrings.Get("Connection/TransportCommand"),
        _ => CoreStrings.Get("Connection/TransportDirect"),
    };

    /// <summary>The transports the form offers for an engine. File databases connect directly only.</summary>
    public static IReadOnlyList<ConnectionTransport> Available(DatabaseEngine engine)
    {
        var descriptor = EngineDescriptor.For(engine);
        if (descriptor.IsFileBased)
        {
            return [ConnectionTransport.Direct];
        }

        // As on macOS, the Cloud SQL Auth Proxy serves only the engines Cloud SQL hosts.
        return engine is DatabaseEngine.PostgreSql or DatabaseEngine.MySql or DatabaseEngine.SqlServer
            ? [ConnectionTransport.Direct, ConnectionTransport.Ssh, ConnectionTransport.Proxy, ConnectionTransport.CloudSqlProxy, ConnectionTransport.CloudflareTunnel, ConnectionTransport.TunnelCommand]
            : [ConnectionTransport.Direct, ConnectionTransport.Ssh, ConnectionTransport.Proxy, ConnectionTransport.CloudflareTunnel, ConnectionTransport.TunnelCommand];
    }

    /// <summary>Every transport the profile has turned on, in a fixed order.</summary>
    public static IReadOnlyList<ConnectionTransport> EnabledTransports(this ConnectionProfile profile)
    {
        ArgumentNullException.ThrowIfNull(profile);
        var enabled = new List<ConnectionTransport>(1);
        if (profile.Ssh is { Enabled: true })
        {
            enabled.Add(ConnectionTransport.Ssh);
        }

        if (profile.Proxy is { Enabled: true })
        {
            enabled.Add(ConnectionTransport.Proxy);
        }

        if (profile.CloudSqlProxy is { Enabled: true })
        {
            enabled.Add(ConnectionTransport.CloudSqlProxy);
        }

        if (profile.CloudflareTunnel is { Enabled: true })
        {
            enabled.Add(ConnectionTransport.CloudflareTunnel);
        }

        if (profile.TunnelCommand is { Enabled: true })
        {
            enabled.Add(ConnectionTransport.TunnelCommand);
        }

        return enabled;
    }

    /// <summary>The one enabled transport, or <see cref="ConnectionTransport.Direct"/> when none or several are on.</summary>
    public static ConnectionTransport ActiveTransport(this ConnectionProfile profile) =>
        profile.EnabledTransports() is [var only] ? only : ConnectionTransport.Direct;

    /// <summary>
    /// Turns <paramref name="transport"/> on and every other one off, keeping each one's settings so switching back
    /// restores what was typed.
    /// </summary>
    public static ConnectionProfile WithTransport(this ConnectionProfile profile, ConnectionTransport transport)
    {
        ArgumentNullException.ThrowIfNull(profile);
        return profile with
        {
            Ssh = Toggle(profile.Ssh, transport == ConnectionTransport.Ssh, static (s, on) => s with { Enabled = on }),
            Proxy = Toggle(profile.Proxy, transport == ConnectionTransport.Proxy, static (s, on) => s with { Enabled = on }),
            CloudSqlProxy = Toggle(profile.CloudSqlProxy, transport == ConnectionTransport.CloudSqlProxy, static (s, on) => s with { Enabled = on }),
            CloudflareTunnel = Toggle(profile.CloudflareTunnel, transport == ConnectionTransport.CloudflareTunnel, static (s, on) => s with { Enabled = on }),
            TunnelCommand = Toggle(profile.TunnelCommand, transport == ConnectionTransport.TunnelCommand, static (s, on) => s with { Enabled = on }),
        };
    }

    /// <summary>
    /// The transport and its settings checked before connecting, with the message the form shows; null when valid.
    /// The messages follow the macOS form's.
    /// </summary>
    public static string? Validate(this ConnectionProfile profile)
    {
        ArgumentNullException.ThrowIfNull(profile);
        var enabled = profile.EnabledTransports();
        if (enabled.Count > 1)
        {
            return CoreStrings.Format("Connection/OnlyOneTransport", string.Join(CoreStrings.Get("Connection/ListSeparator"), enabled.Select(DisplayName)));
        }

        return enabled is [var transport] ? Validate(profile, transport) : null;
    }

    public static bool IsValidPort(int port) => port is > 0 and <= 65535;

    /// <summary>A Cloud SQL instance connection name has at least three non-empty parts split by colons.</summary>
    public static bool IsValidInstanceConnectionName(string? name)
    {
        if (string.IsNullOrWhiteSpace(name))
        {
            return false;
        }

        var parts = name.Trim().Split(':');
        return parts.Length >= 3 && parts.All(p => p.Length > 0);
    }

    private static string? Validate(ConnectionProfile profile, ConnectionTransport transport)
    {
        if (!Available(profile.Engine).Contains(transport))
        {
            return CoreStrings.Format("Connection/TransportUnavailable", profile.Descriptor.DisplayName, transport.DisplayName());
        }

        switch (transport)
        {
            case ConnectionTransport.Ssh when string.IsNullOrWhiteSpace(profile.Ssh!.Host):
                return CoreStrings.Get("Connection/SshHostRequired");
            case ConnectionTransport.Proxy:
                var proxy = profile.Proxy!;
                if (string.IsNullOrWhiteSpace(proxy.Host))
                {
                    return CoreStrings.Get("Connection/ProxyHostRequired");
                }

                return IsValidPort(proxy.Port) ? null : CoreStrings.Get("Connection/ProxyPortRange");
            case ConnectionTransport.CloudSqlProxy:
                var cloudSql = profile.CloudSqlProxy!;
                if (!IsValidInstanceConnectionName(cloudSql.InstanceConnectionName))
                {
                    return CoreStrings.Get("Connection/InstanceConnectionNameFormat");
                }

                return cloudSql.LocalPort is { } cloudSqlPort && !IsValidPort(cloudSqlPort) ? CoreStrings.Get("Connection/LocalPortRange") : null;
            case ConnectionTransport.CloudflareTunnel:
                var cloudflare = profile.CloudflareTunnel!;
                if (string.IsNullOrWhiteSpace(cloudflare.AccessHostname))
                {
                    return CoreStrings.Get("Connection/CloudflareHostRequired");
                }

                return cloudflare.LocalPort is { } cloudflarePort && !IsValidPort(cloudflarePort) ? CoreStrings.Get("Connection/LocalPortRange") : null;
            case ConnectionTransport.TunnelCommand:
                return TunnelCommandLine.Validate(profile.TunnelCommand!);
            default:
                return null;
        }
    }

    private static T? Toggle<T>(T? settings, bool on, Func<T, bool, T> with)
        where T : class, new()
    {
        if (settings is null)
        {
            return on ? with(new T(), true) : null;
        }

        return with(settings, on);
    }
}
