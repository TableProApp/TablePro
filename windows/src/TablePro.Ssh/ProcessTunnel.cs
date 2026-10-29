using System.ComponentModel;
using System.Diagnostics;
using System.Text;
using TablePro.Core.Drivers;
using TablePro.Ssh.Localization;

namespace TablePro.Ssh;

/// <summary>A helper program to start: its arguments go to the OS as a list, its secrets only into its own environment.</summary>
internal sealed record HelperLaunch(string DisplayName, string Executable, IReadOnlyList<string> Arguments, IReadOnlyDictionary<string, string> Environment);

/// <summary>
/// A helper program that listens on a loopback port and forwards to the database: cloud-sql-proxy, cloudflared or a
/// tunnel command. It runs in the app's kill-on-close Job Object like ssh, so it never outlives the app.
/// </summary>
public sealed class ProcessTunnel : IConnectionTunnel
{
    private static readonly TimeSpan PollInterval = TimeSpan.FromMilliseconds(250);
    private static readonly TimeSpan ProbeTimeout = TimeSpan.FromMilliseconds(500);

    private readonly Process _process;
    private readonly StderrLog _output;
    private int _disposed;
    private int _closedRaised;

    private ProcessTunnel(Process process, StderrLog output, string displayName, int localPort, ConnectionRequest request)
    {
        _process = process;
        _output = output;
        DisplayName = displayName;
        LocalPort = localPort;
        Request = request;
        ProcessId = process.Id;
        _process.Exited += OnExited;
        if (_process.HasExited)
        {
            OnExited(_process, EventArgs.Empty);
        }
    }

    /// <summary>Raised once, on a thread-pool thread, when the helper ends while the tunnel is in use.</summary>
    public event EventHandler? Closed;

    public string DisplayName { get; }

    public ConnectionRequest Request { get; }

    public int LocalPort { get; }

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

    public string Diagnostics => _output.ToString();

    public async ValueTask DisposeAsync()
    {
        if (Interlocked.Exchange(ref _disposed, 1) != 0)
        {
            return;
        }

        _process.Exited -= OnExited;
        await SshProcess.TerminateAsync(_process);
    }

    /// <param name="launch">What to run.</param>
    /// <param name="localPort">The loopback port the helper was told to listen on.</param>
    /// <param name="request">The request the driver gets once the port is open.</param>
    /// <param name="timeout">The longest wait for the port to open.</param>
    /// <param name="inspect">Reads the output on every poll, and may fail the start early, as cloudflared's sign-in prompt does.</param>
    /// <param name="cancellationToken">Stops the attempt and ends the helper.</param>
    internal static async Task<ProcessTunnel> StartAsync(
        HelperLaunch launch,
        int localPort,
        ConnectionRequest request,
        TimeSpan timeout,
        Func<string, TunnelException?>? inspect,
        CancellationToken cancellationToken)
    {
        var startInfo = new ProcessStartInfo(launch.Executable)
        {
            UseShellExecute = false,
            CreateNoWindow = true,
            WorkingDirectory = Environment.GetFolderPath(Environment.SpecialFolder.UserProfile),
            RedirectStandardInput = true,
            RedirectStandardOutput = true,
            RedirectStandardError = true,
            StandardErrorEncoding = Encoding.UTF8,
            StandardOutputEncoding = Encoding.UTF8,
        };
        foreach (var argument in launch.Arguments)
        {
            startInfo.ArgumentList.Add(argument);
        }

        foreach (var (name, value) in launch.Environment)
        {
            startInfo.Environment[name] = value;
        }

        // Helpers log to either stream (cloud-sql-proxy to stdout, cloudflared to stderr), so both feed one log.
        var output = new StderrLog();
        var process = new Process { StartInfo = startInfo, EnableRaisingEvents = true };
        process.ErrorDataReceived += (_, e) =>
        {
            if (e.Data is not null)
            {
                output.Append(e.Data);
            }
        };
        process.OutputDataReceived += (_, e) =>
        {
            if (e.Data is not null)
            {
                output.Append(e.Data);
            }
        };

        try
        {
            process.Start();
        }
        catch (Win32Exception ex)
        {
            process.Dispose();
            throw new TunnelException(TunnelFailureKind.ExecutableNotFound, SshStrings.Format("Tunnel/CouldNotStart", launch.Executable, ex.Message), innerException: ex);
        }

        if (OperatingSystem.IsWindows())
        {
            ProcessJob.TryAssign(process);
        }

        process.BeginErrorReadLine();
        process.BeginOutputReadLine();
        process.StandardInput.Close();

        try
        {
            await WaitUntilReadyAsync(process, output, launch.DisplayName, localPort, timeout, inspect, cancellationToken);
        }
        catch
        {
            await SshProcess.TerminateAsync(process);
            throw;
        }

        return new ProcessTunnel(process, output, launch.DisplayName, localPort, request);
    }

    private static async Task WaitUntilReadyAsync(
        Process process,
        StderrLog output,
        string name,
        int localPort,
        TimeSpan timeout,
        Func<string, TunnelException?>? inspect,
        CancellationToken cancellationToken)
    {
        using var deadline = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
        deadline.CancelAfter(timeout);
        try
        {
            var exited = process.WaitForExitAsync(deadline.Token);
            while (true)
            {
                if (process.HasExited)
                {
                    // Lets the asynchronous readers drain, so the error carries the helper's last words.
                    await process.WaitForExitAsync(CancellationToken.None);
                    var text = output.ToString();
                    throw inspect?.Invoke(text) ?? (LocalPortPolicy.IsBindFailure(text)
                        ? new TunnelException(TunnelFailureKind.LocalPortUnavailable, SshStrings.Format("Tunnel/HelperCouldNotListen", name, localPort), text)
                        : new TunnelException(TunnelFailureKind.StartupFailed, WithTail(SshStrings.Format("Tunnel/HelperExitedEarly", name), text), text));
                }

                if (inspect?.Invoke(output.ToString()) is { } early)
                {
                    throw early;
                }

                if (await FreePort.AcceptsConnectionsAsync(localPort, ProbeTimeout, deadline.Token))
                {
                    // cloudflared accepts on its port before Access has signed in, so the output is read once more.
                    if (inspect?.Invoke(output.ToString()) is { } late)
                    {
                        throw late;
                    }

                    await deadline.CancelAsync();
                    return;
                }

                await Task.WhenAny(Task.Delay(PollInterval, deadline.Token), exited);
                deadline.Token.ThrowIfCancellationRequested();
            }
        }
        catch (OperationCanceledException) when (!cancellationToken.IsCancellationRequested)
        {
            var text = output.ToString();
            throw LocalPortPolicy.IsBindFailure(text)
                ? new TunnelException(TunnelFailureKind.LocalPortUnavailable, SshStrings.Format("Tunnel/HelperCouldNotListen", name, localPort), text)
                : new TunnelException(TunnelFailureKind.Timeout, WithTail(SshStrings.Format("Tunnel/HelperTimedOut", name), text), text);
        }
    }

    internal static string WithTail(string summary, string output)
    {
        var tail = SshFailureClassifier.Tail(output);
        return tail.Length == 0 ? summary : summary + Environment.NewLine + Environment.NewLine + tail;
    }

    private void OnExited(object? sender, EventArgs e)
    {
        if (Volatile.Read(ref _disposed) != 0 || Interlocked.Exchange(ref _closedRaised, 1) != 0)
        {
            return;
        }

        Closed?.Invoke(this, EventArgs.Empty);
    }
}
