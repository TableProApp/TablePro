namespace TablePro.Storage.Connections;

// The macOS app's portable connection bundle, so a file exported on one platform opens on the other. One shape
// carries both formats, since format 2 only adds to format 1:
// - format 1 (ConnectionBundleV1) links a connection to its group, tags and credential profile by name, and keys
//   credentials by the connection's position;
// - format 2 (ConnectionBundle) gives every item a file-local ref, nests groups through parentRef, keys credentials by
//   ref, and adds saved queries and their folders.
// Property names and string values follow those files. Credentials appear only inside an encrypted file.

internal sealed class PortableConnectionFile
{
    public int FormatVersion { get; set; } = 1;

    /// <summary>A UTC time with whole seconds, because the macOS decoder's ISO 8601 parser rejects fractions.</summary>
    public DateTime ExportedAt { get; set; }

    public string AppVersion { get; set; } = string.Empty;
    public List<PortableConnection> Connections { get; set; } = [];
    public List<PortableGroup>? Groups { get; set; }
    public List<PortableTag>? Tags { get; set; }
    public List<PortableCredentialProfile>? CredentialProfiles { get; set; }

    /// <summary>Format 1 keys by the connection's index as a string, format 2 by its ref.</summary>
    public Dictionary<string, PortableCredentials>? Credentials { get; set; }

    public List<PortableQueryFolder>? QueryFolders { get; set; }
    public List<PortableSavedQuery>? SavedQueries { get; set; }
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
    public string? IconName { get; set; }
    public string? SafeModeLevel { get; set; }
    public string? AiPolicy { get; set; }
    public int? ConnectTimeoutSeconds { get; set; }
    public int? QueryTimeoutSeconds { get; set; }
    public Dictionary<string, string>? AdditionalFields { get; set; }
    public int? RedisDatabase { get; set; }
    public string? StartupCommands { get; set; }
    public bool? LocalOnly { get; set; }
    public PortableTunnelCommand? TunnelCommand { get; set; }

    // Format 1 links.
    public string? GroupName { get; set; }
    public string? TagName { get; set; }
    public List<string>? TagNames { get; set; }
    public string? CredentialProfileName { get; set; }

    // Format 2 links.
    public string? Ref { get; set; }
    public string? GroupRef { get; set; }
    public string? CredentialProfileRef { get; set; }
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

/// <summary>The macOS <c>ExportableTunnelCommand</c>: the one exported field that names a program to run.</summary>
internal sealed class PortableTunnelCommand
{
    public string Method { get; set; } = string.Empty;
    public string? Command { get; set; }
    public string? ExecutablePath { get; set; }
    public string? KubernetesNamespace { get; set; }
    public string? KubernetesResource { get; set; }
    public string? KubernetesContext { get; set; }
    public string? AwsTarget { get; set; }
    public string? AwsProfile { get; set; }
    public string? AwsRegion { get; set; }
}

internal sealed class PortableGroup
{
    public string? Ref { get; set; }
    public string Name { get; set; } = string.Empty;
    public string? Color { get; set; }
    public string? IconName { get; set; }
    public string? ParentRef { get; set; }
}

internal sealed class PortableTag
{
    public string Name { get; set; } = string.Empty;
    public string? Color { get; set; }
}

internal sealed class PortableCredentialProfile
{
    public string? Ref { get; set; }
    public string Name { get; set; } = string.Empty;
    public string Username { get; set; } = string.Empty;
    public string PasswordMode { get; set; } = "prompt";
    public List<string>? SecureFieldIds { get; set; }
}

internal sealed class PortableCredentials
{
    public string? Password { get; set; }
    public string? SshPassword { get; set; }
    public string? KeyPassphrase { get; set; }
    public string? SslClientKeyPassphrase { get; set; }
    public string? TotpSecret { get; set; }
    public Dictionary<string, string>? PluginSecureFields { get; set; }
}

internal sealed class PortableQueryFolder
{
    public string Ref { get; set; } = string.Empty;
    public string Name { get; set; } = string.Empty;
    public string? ParentRef { get; set; }
    public string? ConnectionRef { get; set; }
}

internal sealed class PortableSavedQuery
{
    public string Ref { get; set; } = string.Empty;
    public string Name { get; set; } = string.Empty;
    public string Sql { get; set; } = string.Empty;
    public string? Keyword { get; set; }
    public string? FolderRef { get; set; }
    public string? ConnectionRef { get; set; }
}
