using TablePro.Core.Drivers;

namespace TablePro.Ssh;

/// <summary>
/// Anything that puts the database behind a loopback port: an SSH forward, a proxy forwarder, or a helper program
/// such as cloud-sql-proxy. Hand <see cref="Request"/> to the driver; disposing closes the tunnel and ends any
/// process it started.
/// </summary>
public interface IConnectionTunnel : IAsyncDisposable
{
    /// <summary>The caller's request with <c>Host</c> and <c>Port</c> pointing at the tunnel's local end.</summary>
    ConnectionRequest Request { get; }

    int LocalPort { get; }

    bool IsAlive { get; }

    /// <summary>What the helper has printed so far, for a details pane.</summary>
    string Diagnostics { get; }
}

/// <summary>Why a tunnel other than SSH failed, so the UI can say what to fix.</summary>
public enum TunnelFailureKind
{
    Unknown,

    /// <summary>The settings cannot run, such as a command without its port placeholder.</summary>
    InvalidSettings,

    /// <summary>cloud-sql-proxy, cloudflared or the tunnel command's program is not installed or not found.</summary>
    ExecutableNotFound,

    /// <summary>No loopback port could be had, or the fixed one is taken.</summary>
    LocalPortUnavailable,

    /// <summary>The helper exited before its port opened.</summary>
    StartupFailed,

    /// <summary>The helper kept running but its port never opened in time.</summary>
    Timeout,

    /// <summary>Cloudflare Access wants a browser sign-in first.</summary>
    BrowserSignInRequired,

    /// <summary>The proxy could not be reached.</summary>
    ProxyUnreachable,

    /// <summary>The proxy turned down the user name and password.</summary>
    ProxyAuthenticationFailed,

    /// <summary>The proxy was reached but would not connect to the database.</summary>
    ProxyRefused,
}

public sealed class TunnelException : Exception
{
    public TunnelException()
    {
    }

    public TunnelException(string message)
        : base(message)
    {
    }

    public TunnelException(string message, Exception innerException)
        : base(message, innerException)
    {
    }

    public TunnelException(TunnelFailureKind kind, string message, string? diagnostics = null, Exception? innerException = null)
        : base(message, innerException)
    {
        Kind = kind;
        Diagnostics = diagnostics ?? string.Empty;
    }

    public TunnelFailureKind Kind { get; }

    /// <summary>The helper's output, for a details pane. Never holds a secret, which only travels in the child's environment.</summary>
    public string Diagnostics { get; } = string.Empty;

    /// <summary>The browser sign-in address cloudflared printed, when <see cref="Kind"/> is <see cref="TunnelFailureKind.BrowserSignInRequired"/>.</summary>
    public Uri? SignInUri { get; init; }
}
