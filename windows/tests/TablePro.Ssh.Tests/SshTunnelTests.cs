using System.Diagnostics;
using System.Net;
using System.Net.Sockets;
using TablePro.Core.Connections;
using TablePro.Core.Drivers;

namespace TablePro.Ssh.Tests;

public sealed class SshTunnelTests
{
    private static CancellationToken Token => TestContext.Current.CancellationToken;

    [Fact]
    public void FreePortIsALoopbackPortNobodyHolds()
    {
        var port = FreePort.Find();

        Assert.InRange(port, 1024, 65535);
        using var listener = new TcpListener(IPAddress.Loopback, port);
        listener.Start();
        listener.Stop();
    }

    [Fact]
    public async Task AcceptsConnectionsTracksWhetherSomethingListens()
    {
        using var listener = new TcpListener(IPAddress.Loopback, 0);
        listener.Start();
        var port = ((IPEndPoint)listener.LocalEndpoint).Port;

        Assert.True(await FreePort.AcceptsConnectionsAsync(port, TimeSpan.FromSeconds(2), Token));
        listener.Stop();
        Assert.False(await FreePort.AcceptsConnectionsAsync(port, TimeSpan.FromSeconds(2), Token));
    }

    [Theory]
    [InlineData("ops@bastion: Permission denied (publickey,password).", SshFailureKind.AuthenticationFailed)]
    [InlineData("Received disconnect from 10.0.0.1 port 22:2: Too many authentication failures", SshFailureKind.AuthenticationFailed)]
    [InlineData("@@@ WARNING: REMOTE HOST IDENTIFICATION HAS CHANGED! @@@\nHost key verification failed.", SshFailureKind.HostKeyRejected)]
    [InlineData("ssh: Could not resolve hostname nope.invalid: No such host is known.", SshFailureKind.HostNotFound)]
    [InlineData("ssh: connect to host 127.0.0.1 port 1: Connection refused", SshFailureKind.ConnectionFailed)]
    [InlineData("ssh: connect to host 10.1.1.1 port 22: Connection timed out", SshFailureKind.ConnectionFailed)]
    [InlineData("bind [127.0.0.1]:50000: Permission denied\nCould not request local forwarding.", SshFailureKind.LocalPortUnavailable)]
    [InlineData("something unexpected", SshFailureKind.Unknown)]
    public void StderrIsClassified(string stderr, SshFailureKind expected) =>
        Assert.Equal(expected, SshFailureClassifier.Classify(stderr));

    [Fact]
    public void SharedRuntimeRootHoldsTheDotnetHost()
    {
        // Tests always run on a shared runtime, so the root must resolve to the folder with dotnet.exe in it.
        var root = SshTunnelFactory.SharedRuntimeRoot();

        Assert.NotNull(root);
        Assert.True(Directory.Exists(Path.Combine(root, "shared", "Microsoft.NETCore.App")));
    }

    [Fact]
    public async Task MissingSshExecutableIsReported()
    {
        var factory = new SshTunnelFactory(new SshTunnelOptions { SshExecutablePath = Path.Combine(Path.GetTempPath(), Guid.NewGuid().ToString("N"), "ssh.exe") });

        var error = await Assert.ThrowsAsync<SshTunnelException>(() => factory.OpenAsync(Request(1), null, Token));

        Assert.Equal(SshFailureKind.SshNotFound, error.Kind);
    }

    [Fact]
    public async Task ProfilesWithoutSshAreRefused()
    {
        var profile = new ConnectionProfile { Name = "direct", Engine = DatabaseEngine.PostgreSql };

        await Assert.ThrowsAsync<ArgumentException>(() => new SshTunnelFactory().OpenAsync(ConnectionRequest.Direct(profile, null), null, Token));
    }

    [Fact]
    public async Task UnreachableSshServerFailsFastWithItsStderr()
    {
        var ssh = SshTunnelFactory.FindSshExecutable();
        if (ssh is null)
        {
            Assert.Skip("The OpenSSH client is not installed.");
            return;
        }

        // Nothing listens on this port, so ssh's TCP connect is refused at once.
        var closedPort = FreePort.Find();
        var factory = new SshTunnelFactory(new SshTunnelOptions { SshExecutablePath = ssh, ReadyTimeout = TimeSpan.FromSeconds(15) });
        var stopwatch = Stopwatch.StartNew();

        var error = await Assert.ThrowsAsync<SshTunnelException>(() => factory.OpenAsync(Request(closedPort), null, Token));

        Assert.True(error.Kind == SshFailureKind.ConnectionFailed, $"{error.Kind}: {error.Message}");
        // OpenSSH words a refused connect as "connect to host ..." or, when the socket comes from a proxy or sandbox layer,
        // "banner exchange: ... Connection refused"; either way its own stderr must reach the error.
        Assert.True(
            error.StandardError.Contains("connect to host 127.0.0.1", StringComparison.OrdinalIgnoreCase)
                || error.StandardError.Contains("Connection refused", StringComparison.OrdinalIgnoreCase),
            error.StandardError);
        Assert.NotNull(error.ExitCode);
        Assert.True(stopwatch.Elapsed < TimeSpan.FromSeconds(10), $"Took {stopwatch.Elapsed}.");
    }

    [Fact]
    public void AskPassPrintsTheSecretAndRefusesHostKeyQuestions()
    {
        using var answer = new StringWriter();
        Assert.Equal(0, AskPass.Answer(["ops@bastion's password: "], "s3crét with spaces", answer));
        Assert.Equal("s3crét with spaces\n", answer.ToString());

        using var hostKey = new StringWriter();
        Assert.Equal(1, AskPass.Answer(["Are you sure you want to continue connecting (yes/no/[fingerprint])? "], "s3cret", hostKey));
        Assert.Empty(hostKey.ToString());

        using var missing = new StringWriter();
        Assert.Equal(1, AskPass.Answer(["password: "], null, missing));
        Assert.Empty(missing.ToString());
    }
    private static ConnectionRequest Request(int sshPort)
    {
        var profile = new ConnectionProfile
        {
            Name = "tunneled",
            Engine = DatabaseEngine.PostgreSql,
            Host = "db.internal",
            ConnectTimeoutSeconds = 5,
            Ssh = new SshTunnelSettings { Enabled = true, Host = "127.0.0.1", Port = sshPort, Username = "nobody" },
        };
        return ConnectionRequest.Direct(profile, null);
    }
}
