namespace TablePro.Ssh;

/// <summary>Why a tunnel failed, read from OpenSSH's exit and its stderr so the UI can say what to fix.</summary>
public enum SshFailureKind
{
    Unknown,

    /// <summary>No ssh.exe: the Windows OpenSSH Client optional feature is not installed.</summary>
    SshNotFound,

    AuthenticationFailed,

    /// <summary>The server's host key differs from the one in known_hosts.</summary>
    HostKeyRejected,

    HostNotFound,

    /// <summary>The SSH server could not be reached: refused, timed out or no route.</summary>
    ConnectionFailed,

    /// <summary>ssh could not listen on the local end of the forward.</summary>
    LocalPortUnavailable,

    /// <summary>ssh kept running but the local port never accepted a connection in time.</summary>
    Timeout,

    /// <summary>The tunnel was up and its ssh process ended.</summary>
    Closed,
}

public sealed class SshTunnelException : Exception
{
    public SshTunnelException()
    {
    }

    public SshTunnelException(string message)
        : base(message)
    {
    }

    public SshTunnelException(string message, Exception innerException)
        : base(message, innerException)
    {
    }

    public SshTunnelException(SshFailureKind kind, string message, string? standardError = null, int? exitCode = null, Exception? innerException = null)
        : base(message, innerException)
    {
        Kind = kind;
        StandardError = standardError ?? string.Empty;
        ExitCode = exitCode;
    }

    public SshFailureKind Kind { get; }

    /// <summary>What ssh printed, for a details pane. Never contains the password, which only the askpass helper sees.</summary>
    public string StandardError { get; } = string.Empty;

    public int? ExitCode { get; }
}

internal static class SshFailureClassifier
{
    public static SshFailureKind Classify(string stderr)
    {
        // Bind failures come first: Windows reports a port in an excluded range as "Permission denied",
        // which would otherwise read as a login failure.
        if (ContainsAny(stderr, "bind [127.0.0.1]", "cannot listen to port", "Could not request local forwarding", "Address already in use"))
        {
            return SshFailureKind.LocalPortUnavailable;
        }

        if (ContainsAny(stderr, "Host key verification failed", "REMOTE HOST IDENTIFICATION HAS CHANGED", "REVOKED HOST KEY", "host key is known for"))
        {
            return SshFailureKind.HostKeyRejected;
        }

        if (ContainsAny(stderr, "Permission denied", "Too many authentication failures", "Authentication failed", "incorrect passphrase", "No more authentication methods"))
        {
            return SshFailureKind.AuthenticationFailed;
        }

        if (ContainsAny(stderr, "Could not resolve hostname", "No such host is known"))
        {
            return SshFailureKind.HostNotFound;
        }

        if (ContainsAny(stderr, "Connection refused", "timed out", "Network is unreachable", "No route to host", "Connection closed by", "Connection reset"))
        {
            return SshFailureKind.ConnectionFailed;
        }

        return SshFailureKind.Unknown;
    }

    public static string Describe(SshFailureKind kind, string host) => kind switch
    {
        SshFailureKind.SshNotFound => "ssh.exe was not found. Install the OpenSSH Client from Settings > System > Optional features.",
        SshFailureKind.AuthenticationFailed => $"The SSH server {host} rejected the login.",
        SshFailureKind.HostKeyRejected => $"The host key of {host} does not match the one in known_hosts. Check it with the server's administrator, then remove the old entry.",
        SshFailureKind.HostNotFound => $"The SSH host {host} could not be found.",
        SshFailureKind.ConnectionFailed => $"Could not reach the SSH server {host}.",
        SshFailureKind.LocalPortUnavailable => "ssh could not listen on the local end of the tunnel.",
        SshFailureKind.Timeout => $"The SSH tunnel through {host} did not open in time.",
        SshFailureKind.Closed => $"The SSH tunnel through {host} closed.",
        _ => $"ssh could not open a tunnel through {host}.",
    };

    /// <summary>The last lines of stderr, which is where OpenSSH puts the reason it gave up.</summary>
    public static string Tail(string stderr, int maxLines = 6)
    {
        var lines = stderr.Split('\n', StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries);
        return string.Join(Environment.NewLine, lines.Skip(Math.Max(0, lines.Length - maxLines)));
    }

    private static bool ContainsAny(string text, params ReadOnlySpan<string> needles)
    {
        foreach (var needle in needles)
        {
            if (text.Contains(needle, StringComparison.OrdinalIgnoreCase))
            {
                return true;
            }
        }

        return false;
    }
}
