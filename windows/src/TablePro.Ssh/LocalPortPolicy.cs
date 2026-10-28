namespace TablePro.Ssh;

/// <summary>
/// Which loopback ports a helper program is started on. A fixed port gets one try, because the user chose it and
/// another program holding it is something to report rather than work around. An automatic port is asked of the OS
/// each time; another program can take it before the helper binds, so a bind failure earns a fresh port.
/// </summary>
public sealed class LocalPortPolicy
{
    private readonly Func<int> _allocate;

    public LocalPortPolicy(int? fixedPort, int automaticAttempts, Func<int>? allocate = null)
    {
        if (fixedPort is { } port && port is <= 0 or > 65535)
        {
            throw new ArgumentOutOfRangeException(nameof(fixedPort), port, "A port is between 1 and 65535.");
        }

        FixedPort = fixedPort;
        Attempts = fixedPort is null ? Math.Max(1, automaticAttempts) : 1;
        _allocate = allocate ?? FreePort.Find;
    }

    public int? FixedPort { get; }

    public int Attempts { get; }

    public bool IsAutomatic => FixedPort is null;

    /// <summary>The port for the attempt numbered from 1.</summary>
    public int PortFor(int attempt)
    {
        ArgumentOutOfRangeException.ThrowIfLessThan(attempt, 1);
        ArgumentOutOfRangeException.ThrowIfGreaterThan(attempt, Attempts);
        return FixedPort ?? _allocate();
    }

    /// <summary>Whether a failure to bind on <paramref name="attempt"/> should be retried with a new port.</summary>
    public bool RetriesAfter(int attempt) => IsAutomatic && attempt < Attempts;

    /// <summary>Whether the helper's output says it could not listen on its port.</summary>
    public static bool IsBindFailure(string output) =>
        output.Contains("address already in use", StringComparison.OrdinalIgnoreCase)
        || output.Contains("Only one usage of each socket address", StringComparison.OrdinalIgnoreCase)
        || output.Contains("bind: An attempt was made to access a socket", StringComparison.OrdinalIgnoreCase);
}
