using System.Diagnostics;
using TablePro.Core.Connections;
using TablePro.Core.Drivers;

namespace TablePro.Ssh.Tests;

/// <summary>Drives the factory against a fake ssh that opens the forward, to check readiness, rewriting and teardown.</summary>
[Collection(FakeSshCollection.Name)]
public sealed class SshTunnelLifecycleTests : IAsyncLifetime
{
    private readonly string _directory = Path.Combine(Path.GetTempPath(), "tp-fakessh-" + Guid.NewGuid().ToString("N")[..8]);

    private static CancellationToken Token => TestContext.Current.CancellationToken;

    private string FakeSsh => Path.Combine(_directory, "TablePro.Ssh.FakeSsh.exe");

    public ValueTask InitializeAsync()
    {
        // CreateProcess refuses an executable path past MAX_PATH, which a deep checkout can reach; a short copy avoids it.
        Directory.CreateDirectory(_directory);
        foreach (var file in Directory.GetFiles(AppContext.BaseDirectory, "TablePro.Ssh.FakeSsh.*"))
        {
            File.Copy(file, Path.Combine(_directory, Path.GetFileName(file)));
        }

        // The fake is framework-dependent; children inherit this so it finds the runtime the tests run on.
        if (Environment.GetEnvironmentVariable("DOTNET_ROOT") is null && SshTunnelFactory.SharedRuntimeRoot() is { } root)
        {
            Environment.SetEnvironmentVariable("DOTNET_ROOT", root);
        }

        return ValueTask.CompletedTask;
    }

    public async ValueTask DisposeAsync()
    {
        for (var attempt = 0; attempt < 20; attempt++)
        {
            try
            {
                Directory.Delete(_directory, recursive: true);
                return;
            }
            catch (Exception ex) when (ex is IOException or UnauthorizedAccessException)
            {
                await Task.Delay(100, CancellationToken.None);
            }
        }
    }

    [Fact]
    public async Task OpenTunnelRewritesTheRequestAndDisposeKillsSsh()
    {
        var factory = new SshTunnelFactory(new SshTunnelOptions { SshExecutablePath = FakeSsh });
        var request = Request("ops");

        var tunnel = await factory.OpenAsync(request, null, Token);
        var processId = tunnel.ProcessId;
        var closed = false;
        tunnel.Closed += (_, _) => closed = true;

        Assert.True(tunnel.IsAlive);
        Assert.Equal("127.0.0.1", tunnel.Request.Host);
        Assert.Equal(tunnel.LocalPort, tunnel.Request.Port);
        Assert.Same(request.Profile, tunnel.Request.Profile);
        Assert.Equal(request.Database, tunnel.Request.Database);
        Assert.True(await FreePort.AcceptsConnectionsAsync(tunnel.LocalPort, TimeSpan.FromSeconds(2), Token));

        await tunnel.DisposeAsync();

        Assert.False(tunnel.IsAlive);
        Assert.False(closed);
        Assert.False(IsRunning(processId));
        Assert.False(await FreePort.AcceptsConnectionsAsync(tunnel.LocalPort, TimeSpan.FromSeconds(1), Token));
        await tunnel.DisposeAsync();
    }

    [Fact]
    public async Task SshDyingUnderAnOpenTunnelRaisesClosed()
    {
        var factory = new SshTunnelFactory(new SshTunnelOptions { SshExecutablePath = FakeSsh });
        await using var tunnel = await factory.OpenAsync(Request("ops"), null, Token);
        var closed = new TaskCompletionSource<SshTunnelException>(TaskCreationOptions.RunContinuationsAsynchronously);
        tunnel.Closed += (_, e) => closed.TrySetResult(e.Error);

        using (var process = Process.GetProcessById(tunnel.ProcessId))
        {
            process.Kill();
        }

        var error = await closed.Task.WaitAsync(TimeSpan.FromSeconds(10), Token);
        Assert.Equal(SshFailureKind.Closed, error.Kind);
        Assert.False(tunnel.IsAlive);
    }

    [Fact]
    public async Task LoginFailureSurfacesStderrAsTheError()
    {
        var factory = new SshTunnelFactory(new SshTunnelOptions { SshExecutablePath = FakeSsh });

        var error = await Assert.ThrowsAsync<SshTunnelException>(() => factory.OpenAsync(Request("denied"), null, Token));

        Assert.Equal(SshFailureKind.AuthenticationFailed, error.Kind);
        Assert.Equal(255, error.ExitCode);
        Assert.Contains("Permission denied", error.Message, StringComparison.Ordinal);
    }

    [Fact]
    public async Task ATunnelThatNeverOpensTimesOutAndLeavesNoProcess()
    {
        var factory = new SshTunnelFactory(new SshTunnelOptions { SshExecutablePath = FakeSsh, ReadyTimeout = TimeSpan.FromSeconds(1) });
        var before = RunningFakes();

        var error = await Assert.ThrowsAsync<SshTunnelException>(() => factory.OpenAsync(Request("hang", connectTimeoutSeconds: 1), null, Token));

        Assert.Equal(SshFailureKind.Timeout, error.Kind);
        Assert.Empty(RunningFakes().Except(before));
    }

    [Fact]
    public async Task CancellingTheOpenKillsSsh()
    {
        var factory = new SshTunnelFactory(new SshTunnelOptions { SshExecutablePath = FakeSsh });
        var before = RunningFakes();
        using var cancel = CancellationTokenSource.CreateLinkedTokenSource(Token);
        cancel.CancelAfter(TimeSpan.FromMilliseconds(500));

        await Assert.ThrowsAnyAsync<OperationCanceledException>(() => factory.OpenAsync(Request("hang"), null, cancel.Token));

        Assert.Empty(RunningFakes().Except(before));
    }

    private static ConnectionRequest Request(string user, int connectTimeoutSeconds = 5)
    {
        var profile = new ConnectionProfile
        {
            Name = "fake",
            Engine = DatabaseEngine.PostgreSql,
            Host = "db.internal",
            Database = "app",
            ConnectTimeoutSeconds = connectTimeoutSeconds,
            Ssh = new SshTunnelSettings { Enabled = true, Host = "bastion", Username = user },
        };
        return ConnectionRequest.Direct(profile, "db-password");
    }

    private static bool IsRunning(int processId)
    {
        try
        {
            using var process = Process.GetProcessById(processId);
            return !process.HasExited;
        }
        catch (ArgumentException)
        {
            return false;
        }
    }

    private static HashSet<int> RunningFakes()
    {
        var processes = Process.GetProcessesByName("TablePro.Ssh.FakeSsh");
        try
        {
            return [.. processes.Where(p => !p.HasExited).Select(p => p.Id)];
        }
        finally
        {
            foreach (var process in processes)
            {
                process.Dispose();
            }
        }
    }
}
