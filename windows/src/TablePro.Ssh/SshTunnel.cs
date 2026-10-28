using System.Diagnostics;
using System.Text;
using TablePro.Core.Drivers;

namespace TablePro.Ssh;

public sealed class SshTunnelClosedEventArgs(SshTunnelException error) : EventArgs
{
    public SshTunnelException Error { get; } = error;
}

/// <summary>
/// A running <c>ssh -N -L</c> forward. Hand <see cref="Request"/> to the driver; it dials the local end.
/// Disposing kills ssh and anything it started.
/// </summary>
public sealed class SshTunnel : IAsyncDisposable
{
    private readonly Process _process;
    private readonly StderrLog _stderr;
    private readonly string _sshHost;
    private int _disposed;
    private int _closedRaised;

    internal SshTunnel(Process process, StderrLog stderr, int localPort, ConnectionRequest request, string sshHost)
    {
        _process = process;
        _stderr = stderr;
        _sshHost = sshHost;
        LocalPort = localPort;
        Request = request;
        ProcessId = process.Id;
        _process.Exited += OnProcessExited;

        // The process may have ended between the readiness check and the subscription above.
        if (_process.HasExited)
        {
            OnProcessExited(_process, EventArgs.Empty);
        }
    }

    /// <summary>
    /// Raised once, on a thread-pool thread, when ssh ends while the tunnel is still in use: the network dropped, the
    /// server restarted, or keepalives went unanswered. Not raised by <see cref="DisposeAsync"/>.
    /// </summary>
    public event EventHandler<SshTunnelClosedEventArgs>? Closed;

    public int LocalPort { get; }

    /// <summary>The caller's request with <c>Host</c> and <c>Port</c> pointing at the tunnel's local end.</summary>
    public ConnectionRequest Request { get; }

    public int ProcessId { get; }

    public bool IsAlive
    {
        get
        {
            if (Volatile.Read(ref _disposed) != 0)
            {
                return false;
            }

            try
            {
                return !_process.HasExited;
            }
            catch (InvalidOperationException)
            {
                return false;
            }
        }
    }

    /// <summary>What ssh has printed so far, such as a channel that failed to open on the far side.</summary>
    public string StandardError => _stderr.ToString();

    public async ValueTask DisposeAsync()
    {
        if (Interlocked.Exchange(ref _disposed, 1) != 0)
        {
            return;
        }

        _process.Exited -= OnProcessExited;
        await SshProcess.TerminateAsync(_process);
    }

    private void OnProcessExited(object? sender, EventArgs e)
    {
        if (Volatile.Read(ref _disposed) != 0 || Interlocked.Exchange(ref _closedRaised, 1) != 0)
        {
            return;
        }

        int? exitCode = null;
        try
        {
            exitCode = _process.ExitCode;
        }
        catch (InvalidOperationException)
        {
        }

        var stderr = _stderr.ToString();
        var error = new SshTunnelException(
            SshFailureKind.Closed,
            SshFailureClassifier.Describe(SshFailureKind.Closed, _sshHost),
            stderr,
            exitCode);
        Closed?.Invoke(this, new SshTunnelClosedEventArgs(error));
    }
}

/// <summary>Keeps the last few kilobytes of ssh's stderr; a long-lived tunnel that logs channel errors must not grow without bound.</summary>
internal sealed class StderrLog
{
    private const int MaxChars = 16 * 1024;
    private readonly StringBuilder _text = new();
    private readonly Lock _lock = new();

    public void Append(string line)
    {
        lock (_lock)
        {
            _text.Append(line).Append('\n');
            if (_text.Length > MaxChars)
            {
                _text.Remove(0, _text.Length - MaxChars);
            }
        }
    }

    public override string ToString()
    {
        lock (_lock)
        {
            return _text.ToString();
        }
    }
}

internal static class SshProcess
{
    public static async Task TerminateAsync(Process process)
    {
        try
        {
            if (!process.HasExited)
            {
                // ssh may have started a ProxyJump ssh and the askpass helper; they must go with it.
                process.Kill(entireProcessTree: true);
            }

            using var wait = new CancellationTokenSource(TimeSpan.FromSeconds(5));
            await process.WaitForExitAsync(wait.Token);
        }
        catch (InvalidOperationException)
        {
        }
        catch (OperationCanceledException)
        {
        }
        catch (System.ComponentModel.Win32Exception)
        {
        }
        finally
        {
            process.Dispose();
        }
    }
}
