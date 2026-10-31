namespace TablePro.Core.Connections;

/// <summary>
/// A saved connection. The password never lives here: it is kept by the credential vault under <see cref="Id"/>.
/// </summary>
public sealed record ConnectionProfile
{
    public Guid Id { get; init; } = Guid.NewGuid();
    public required string Name { get; init; }
    public required DatabaseEngine Engine { get; init; }
    public string Host { get; init; } = "localhost";
    public int Port { get; init; }
    public string? Database { get; init; }
    public string? Username { get; init; }

    /// <summary>The database file for SQLite and DuckDB. Network engines ignore it.</summary>
    public string? FilePath { get; init; }

    public SslMode SslMode { get; init; } = SslMode.Preferred;
    public SafeModeLevel SafeMode { get; init; } = SafeModeLevel.Silent;
    public ConnectionColor Color { get; init; } = ConnectionColor.None;
    public string? Group { get; init; }
    public bool SavePassword { get; init; } = true;
    public int ConnectTimeoutSeconds { get; init; } = 15;
    public DateTimeOffset? LastConnectedAt { get; init; }

    public SshTunnelSettings? Ssh { get; init; }

    // The transports below are null in a profile that never used them, so connections.json written before they
    // existed loads unchanged. At most one transport, SSH included, is enabled; see ConnectionTransports.

    public ProxySettings? Proxy { get; init; }

    public CloudSqlProxySettings? CloudSqlProxy { get; init; }

    public CloudflareTunnelSettings? CloudflareTunnel { get; init; }

    public TunnelCommandSettings? TunnelCommand { get; init; }

    /// <summary>A sign-in other than the saved password, such as Kerberos, IAM or Entra ID. Null signs in with the password.</summary>
    public ConnectionAuthSettings? Auth { get; init; }

    public ExternalAccessLevel ExternalAccess { get; init; } = ExternalAccessLevel.ReadOnly;

    public AiPolicy AiPolicy { get; init; } = AiPolicy.AskEachTime;

    /// <summary>SQL run on every new connection, such as <c>SET search_path</c>.</summary>
    public string? StartupCommands { get; init; }

    /// <summary>Engine-specific connection string keywords the form has no field for.</summary>
    public IReadOnlyDictionary<string, string> AdditionalOptions { get; init; } = new Dictionary<string, string>();

    /// <summary>Opens the database read-only at the driver, beyond what Safe Mode refuses in the app.</summary>
    public bool IsReadOnly => SafeMode.BlocksAllWrites() || Descriptor.IsReadOnly;

    public EngineDescriptor Descriptor => EngineDescriptor.For(Engine);

    public int EffectivePort => Port > 0 ? Port : SslMode >= SslMode.Required && Descriptor.TlsDefaultPort is { } tls ? tls : Descriptor.DefaultPort;

    /// <summary>What the picker shows under the name.</summary>
    public string Subtitle => Descriptor.IsFileBased
        ? FilePath ?? string.Empty
        : string.IsNullOrEmpty(Database)
            ? $"{Host}:{EffectivePort}"
            : $"{Host}:{EffectivePort}/{Database}";
}
