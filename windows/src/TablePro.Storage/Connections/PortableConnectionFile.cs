namespace TablePro.Storage.Connections;

// The shape of the macOS app's format 1 connection bundle (ConnectionBundleV1), so a file exported on one platform
// opens on the other. Property names and string values follow that file; nothing here carries a password.

internal sealed class PortableConnectionFile
{
    public int FormatVersion { get; set; } = 1;

    /// <summary>A UTC time with whole seconds, because the macOS decoder's ISO 8601 parser rejects fractions.</summary>
    public DateTime ExportedAt { get; set; }

    public string AppVersion { get; set; } = string.Empty;
    public List<PortableConnection> Connections { get; set; } = [];
    public List<PortableGroup>? Groups { get; set; }
}

internal sealed class PortableConnection
{
    public string Name { get; set; } = string.Empty;
    public string Host { get; set; } = string.Empty;
    public int Port { get; set; }
    public string Database { get; set; } = string.Empty;
    public string Username { get; set; } = string.Empty;
    public string Type { get; set; } = string.Empty;
    public PortableSshConfig? SshConfig { get; set; }
    public PortableSslConfig? SslConfig { get; set; }
    public string? Color { get; set; }
    public string? SafeModeLevel { get; set; }
    public string? AiPolicy { get; set; }
    public int? ConnectTimeoutSeconds { get; set; }
    public Dictionary<string, string>? AdditionalFields { get; set; }
    public string? StartupCommands { get; set; }
    public string? GroupName { get; set; }
}

internal sealed class PortableSshConfig
{
    public bool Enabled { get; set; }
    public string Host { get; set; } = string.Empty;
    public int? Port { get; set; }
    public string Username { get; set; } = string.Empty;
    public string AuthMethod { get; set; } = string.Empty;
    public string PrivateKeyPath { get; set; } = string.Empty;
    public string AgentSocketPath { get; set; } = string.Empty;
    public List<PortableJumpHost>? JumpHosts { get; set; }
}

internal sealed class PortableJumpHost
{
    public string Host { get; set; } = string.Empty;
    public int? Port { get; set; }
    public string Username { get; set; } = string.Empty;
    public string AuthMethod { get; set; } = string.Empty;
    public string PrivateKeyPath { get; set; } = string.Empty;
}

internal sealed class PortableSslConfig
{
    public string Mode { get; set; } = string.Empty;
}

internal sealed class PortableGroup
{
    public string Name { get; set; } = string.Empty;
    public string? Color { get; set; }
}
