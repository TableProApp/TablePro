using System.ComponentModel;
using System.Diagnostics;
using System.Text;
using TablePro.Core.Connections;
using TablePro.Core.Drivers;

namespace TablePro.Ssh;

public sealed record SshTunnelOptions
{
    /// <summary>Null finds the Windows OpenSSH client, then ssh.exe on PATH.</summary>
    public string? SshExecutablePath { get; init; }

    /// <summary>The program ssh runs to ask for a password. Null uses the running app, which answers as <see cref="AskPass"/>.</summary>
    public string? AskPassPath { get; init; }

    /// <summary>The longest wait for the forward to open, on top of the profile's connect timeout.</summary>
    public TimeSpan ReadyTimeout { get; init; } = TimeSpan.FromSeconds(20);

    public int ServerAliveIntervalSeconds { get; init; } = 30;

    /// <summary>Fresh ports to try when another process takes the chosen one before ssh binds it.</summary>
    public int PortAttempts { get; init; } = 3;
}

public interface ISshTunnelFactory
{
    /// <param name="request">The request whose profile has SSH enabled. Its Host and Port are dialed from the SSH server.</param>
    /// <param name="secret">The SSH password, or the private key's passphrase. Null relies on the agent or an unencrypted key.</param>
    /// <param name="cancellationToken">Stops the attempt and kills ssh.</param>
    Task<SshTunnel> OpenAsync(ConnectionRequest request, string? secret, CancellationToken cancellationToken);
}

/// <summary>
/// Opens tunnels with the system OpenSSH client, so the user's <c>~/.ssh/config</c>, known_hosts, agent and
/// certificates apply as they do in a terminal (Linux ADR 0013).
/// </summary>
public sealed class SshTunnelFactory(SshTunnelOptions? options = null) : ISshTunnelFactory
{
    internal const string SecretVariable = "TABLEPRO_SSH_SECRET";

    private static readonly TimeSpan PollInterval = TimeSpan.FromMilliseconds(100);
    private static readonly TimeSpan ProbeTimeout = TimeSpan.FromMilliseconds(500);

    private readonly SshTunnelOptions _options = options ?? new SshTunnelOptions();

    /// <summary>The ssh.exe the factory would run, or null when the OpenSSH Client is not installed.</summary>
    public static string? FindSshExecutable()
    {
        var systemRoot = Environment.GetEnvironmentVariable("SystemRoot");
        if (!string.IsNullOrEmpty(systemRoot))
        {
            var system = Path.Combine(systemRoot, "System32", "OpenSSH", "ssh.exe");
            if (File.Exists(system))
            {
                return system;
            }
        }

        var name = OperatingSystem.IsWindows() ? "ssh.exe" : "ssh";
        foreach (var directory in (Environment.GetEnvironmentVariable("PATH") ?? string.Empty).Split(Path.PathSeparator, StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries))
        {
            try
            {
                var candidate = Path.Combine(directory.Trim('"'), name);
                if (File.Exists(candidate))
                {
                    return candidate;
                }
            }
            catch (ArgumentException)
            {
                // A PATH entry with characters no path may contain; skip it like the shell would.
            }
        }

        return null;
    }

    public async Task<SshTunnel> OpenAsync(ConnectionRequest request, string? secret, CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(request);
        var settings = request.Profile.Ssh;
        if (settings is not { Enabled: true })
        {
            throw new ArgumentException("The connection does not use SSH.", nameof(request));
        }

        var ssh = _options.SshExecutablePath ?? FindSshExecutable();
        if (ssh is null || !File.Exists(ssh))
        {
            throw new SshTunnelException(SshFailureKind.SshNotFound, SshFailureClassifier.Describe(SshFailureKind.SshNotFound, settings.Host));
        }

        var answersPrompts = !string.IsNullOrEmpty(secret);
        string? askPass = null;
        if (answersPrompts)
        {
            askPass = _options.AskPassPath ?? Environment.ProcessPath ?? string.Empty;
            if (!File.Exists(askPass))
            {
                throw new SshTunnelException(SshFailureKind.Unknown, $"The SSH password helper is missing from {askPass}. Reinstall TablePro.");
            }
        }

        var attempts = Math.Max(1, _options.PortAttempts);
        for (var attempt = 1; ; attempt++)
        {
            try
            {
                return await StartAsync(ssh, askPass, secret, request, settings, FreePort.Find(), cancellationToken);
            }
            catch (SshTunnelException ex) when (ex.Kind == SshFailureKind.LocalPortUnavailable && attempt < attempts)
            {
            }
        }
    }

    private async Task<SshTunnel> StartAsync(
        string ssh,
        string? askPass,
        string? secret,
        ConnectionRequest request,
        SshTunnelSettings settings,
        int localPort,
        CancellationToken cancellationToken)
    {
        var connectTimeout = Math.Max(1, request.Profile.ConnectTimeoutSeconds);
        var arguments = SshArguments.Build(
            settings,
            request.Host,
            request.Port,
            localPort,
            connectTimeout,
            _options.ServerAliveIntervalSeconds,
            answersPrompts: askPass is not null);

        var startInfo = new ProcessStartInfo(ssh)
        {
            UseShellExecute = false,
            CreateNoWindow = true,

            // Where a terminal would start ssh, so a relative key path resolves the same way. It also keeps the app's
            // own working directory, which may be a long install path CreateProcess rejects, out of the call.
            WorkingDirectory = Environment.GetFolderPath(Environment.SpecialFolder.UserProfile),
            RedirectStandardInput = true,
            RedirectStandardOutput = true,
            RedirectStandardError = true,
            StandardErrorEncoding = Encoding.UTF8,
            StandardOutputEncoding = Encoding.UTF8,
        };
        foreach (var argument in arguments)
        {
            startInfo.ArgumentList.Add(argument);
        }

        // Set on this child's environment block only, never on the app's own environment.
        startInfo.Environment.Remove(SecretVariable);
        if (askPass is not null)
        {
            startInfo.Environment["SSH_ASKPASS"] = askPass;
            startInfo.Environment["SSH_ASKPASS_REQUIRE"] = "force";
            startInfo.Environment[SecretVariable] = secret;
            startInfo.Environment[AskPass.ModeVariable] = "1";

            // OpenSSH before 8.4 consults askpass only when DISPLAY is set and ignores SSH_ASKPASS_REQUIRE.
            startInfo.Environment.TryAdd("DISPLAY", "localhost:0");

            // A framework-dependent helper finds the runtime through DOTNET_ROOT when it is not installed system-wide.
            if (SharedRuntimeRoot() is { } dotnetRoot)
            {
                startInfo.Environment.TryAdd("DOTNET_ROOT", dotnetRoot);
            }
        }

        var stderr = new StderrLog();
        var process = new Process { StartInfo = startInfo, EnableRaisingEvents = true };
        process.ErrorDataReceived += (_, e) =>
        {
            if (e.Data is not null)
            {
                stderr.Append(e.Data);
            }
        };

        // ssh -N writes nothing to stdout, but an undrained pipe would block it if it ever did.
        process.OutputDataReceived += static (_, _) => { };

        try
        {
            process.Start();
        }
        catch (Win32Exception ex)
        {
            process.Dispose();
            throw new SshTunnelException(SshFailureKind.SshNotFound, $"Could not start {ssh}: {ex.Message}", innerException: ex);
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
            await WaitUntilReadyAsync(process, stderr, localPort, settings.Host, TimeSpan.FromSeconds(connectTimeout) + _options.ReadyTimeout, cancellationToken);
        }
        catch
        {
            await SshProcess.TerminateAsync(process);
            throw;
        }

        var tunneled = request with { Host = SshArguments.LoopbackAddress, Port = localPort };
        return new SshTunnel(process, stderr, localPort, tunneled, settings.Host);
    }

    private static async Task WaitUntilReadyAsync(Process process, StderrLog stderr, int localPort, string sshHost, TimeSpan timeout, CancellationToken cancellationToken)
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
                    // Lets the async stderr reader drain, so the error carries ssh's last words.
                    await process.WaitForExitAsync(CancellationToken.None);
                    throw Failure(process.ExitCode, stderr.ToString(), sshHost);
                }

                // ssh binds the forward only after the login succeeds, so an accepted connection means the tunnel is up.
                if (await FreePort.AcceptsConnectionsAsync(localPort, ProbeTimeout, deadline.Token))
                {
                    // Releases the exit wait's handler on the Process, which would otherwise live as long as the tunnel.
                    await deadline.CancelAsync();
                    return;
                }

                await Task.WhenAny(Task.Delay(PollInterval, deadline.Token), exited);
                deadline.Token.ThrowIfCancellationRequested();
            }
        }
        catch (OperationCanceledException) when (!cancellationToken.IsCancellationRequested)
        {
            var text = stderr.ToString();
            var kind = SshFailureClassifier.Classify(text);
            if (kind == SshFailureKind.Unknown)
            {
                kind = SshFailureKind.Timeout;
            }

            throw new SshTunnelException(kind, WithDetail(SshFailureClassifier.Describe(kind, sshHost), text), text);
        }
    }

    /// <summary>
    /// The dotnet folder the app runs from, when it runs on a shared runtime (shared\Microsoft.NETCore.App\version).
    /// Null for a self-contained app, whose runtime folder is its own and holds no dotnet.exe.
    /// </summary>
    internal static string? SharedRuntimeRoot()
    {
        var runtime = System.Runtime.InteropServices.RuntimeEnvironment.GetRuntimeDirectory().TrimEnd(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar);
        var root = runtime.Length == 0 ? null : Path.GetDirectoryName(Path.GetDirectoryName(Path.GetDirectoryName(runtime)));
        var host = OperatingSystem.IsWindows() ? "dotnet.exe" : "dotnet";
        return root is not null && File.Exists(Path.Combine(root, host)) ? root : null;
    }

    private static SshTunnelException Failure(int exitCode, string stderr, string sshHost)
    {
        var kind = SshFailureClassifier.Classify(stderr);
        return new SshTunnelException(kind, WithDetail(SshFailureClassifier.Describe(kind, sshHost), stderr), stderr, exitCode);
    }

    private static string WithDetail(string summary, string stderr)
    {
        var tail = SshFailureClassifier.Tail(stderr);
        return tail.Length == 0 ? summary : summary + Environment.NewLine + tail;
    }
}
