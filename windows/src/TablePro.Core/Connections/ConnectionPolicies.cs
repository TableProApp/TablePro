namespace TablePro.Core.Connections;

public enum SshAuthMethod
{
    /// <summary>Keys the OpenSSH agent (or Pageant through its bridge) already holds.</summary>
    Agent,
    PrivateKey,
    Password,
}

/// <summary>An SSH hop the app dials with the system OpenSSH client before it reaches the database.</summary>
public sealed record SshTunnelSettings
{
    public bool Enabled { get; init; }
    public string Host { get; init; } = string.Empty;
    public int Port { get; init; } = 22;
    public string? Username { get; init; }
    public SshAuthMethod AuthMethod { get; init; } = SshAuthMethod.Agent;
    public string? PrivateKeyPath { get; init; }

    /// <summary>Optional ProxyJump hosts, as <c>user@host:port</c>, comma separated.</summary>
    public string? JumpHosts { get; init; }
}

/// <summary>What an MCP client may do with a connection. Same levels as the macOS app's <c>ExternalAccessLevel</c>.</summary>
public enum ExternalAccessLevel
{
    Blocked,
    ReadOnly,
    ReadWrite,
}

/// <summary>Whether the AI assistant may send a connection's schema and SQL to the chosen provider.</summary>
public enum AiPolicy
{
    AskEachTime,
    Allow,
    Never,
}
