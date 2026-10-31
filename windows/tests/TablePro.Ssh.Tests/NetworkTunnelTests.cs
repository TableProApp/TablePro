using System.Net;
using System.Net.Sockets;
using System.Text;
using TablePro.Core.Connections;
using TablePro.Core.Drivers;
using TablePro.Ssh.SignIn;

namespace TablePro.Ssh.Tests;

/// <summary>
/// Tests that start the fake ssh share a collection: the SSH lifecycle tests count running fakes to prove none is
/// left behind, and a fake started by a test running beside them would be counted.
/// </summary>
[CollectionDefinition(Name)]
public sealed class FakeSshCollection
{
    public const string Name = "Fake ssh processes";
}

/// <summary>The proxy forwarder, the helper launch arguments and the tunnel command runner.</summary>
[Collection(FakeSshCollection.Name)]
public sealed class NetworkTunnelTests : IAsyncLifetime
{
    private readonly string _directory = Path.Combine(Path.GetTempPath(), "tp-net-" + Guid.NewGuid().ToString("N")[..8]);

    private static CancellationToken Token => TestContext.Current.CancellationToken;

    private string FakeSsh => Path.Combine(_directory, "TablePro.Ssh.FakeSsh.exe");

    public ValueTask InitializeAsync()
    {
        Directory.CreateDirectory(_directory);
        foreach (var file in Directory.GetFiles(AppContext.BaseDirectory, "TablePro.Ssh.FakeSsh.*"))
        {
            File.Copy(file, Path.Combine(_directory, Path.GetFileName(file)));
        }

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
    public void SocksConnectRequestSendsHostNamesForTheProxyToResolve()
    {
        Assert.Equal([5, 1, 0, 3, 7, (byte)'d', (byte)'b', (byte)'.', (byte)'t', (byte)'e', (byte)'s', (byte)'t', 0x15, 0x38], ProxyHandshake.ConnectRequest("db.test", 5432));
        Assert.Equal([5, 1, 0, 1, 10, 0, 0, 7, 0x0C, 0xEA], ProxyHandshake.ConnectRequest("10.0.0.7", 3306));
        Assert.Equal(4, ProxyHandshake.ConnectRequest("::1", 1)[3]);
        Assert.Equal(4 + 16 + 2, ProxyHandshake.ConnectRequest("::1", 1).Length);
    }

    [Fact]
    public void SocksUserPasswordRequestFollowsRfc1929()
    {
        Assert.Equal([1, 2, (byte)'m', (byte)'e', 3, (byte)'p', (byte)'w', (byte)'d'], ProxyHandshake.UserPasswordRequest("me", "pwd"));
        Assert.Throws<TunnelException>(() => ProxyHandshake.UserPasswordRequest(new string('x', 256), "p"));
    }

    [Fact]
    public void HttpConnectRequestCarriesBasicProxyAuthorization()
    {
        Assert.Equal(
            "CONNECT db:5432 HTTP/1.1\r\nHost: db:5432\r\nProxy-Authorization: Basic bWU6cHdk\r\n\r\n",
            ProxyHandshake.HttpConnectRequest("db", 5432, "me", "pwd"));
        Assert.Equal("CONNECT [::1]:1 HTTP/1.1\r\nHost: [::1]:1\r\n\r\n", ProxyHandshake.HttpConnectRequest("::1", 1, null, null));
    }

    [Theory]
    [InlineData(ProxyProtocol.Socks5)]
    [InlineData(ProxyProtocol.HttpConnect)]
    public async Task ForwarderCarriesBytesThroughTheProxy(ProxyProtocol protocol)
    {
        using var echo = EchoServer.Start();
        await using var proxy = FakeProxy.Start(protocol, echo.Port, "me", "pwd");
        var request = Request("db.internal.test", 5432);
        var settings = new ProxySettings { Enabled = true, Protocol = protocol, Host = "127.0.0.1", Port = proxy.Port, Username = "me" };

        await using var forwarder = await ProxyForwarder.StartAsync(request, settings, "pwd", TimeSpan.FromSeconds(5), Token);

        Assert.Equal("127.0.0.1", forwarder.Request.Host);
        Assert.Equal(forwarder.LocalPort, forwarder.Request.Port);
        Assert.True(forwarder.IsAlive);
        for (var i = 0; i < 2; i++)
        {
            using var client = new TcpClient();
            await client.ConnectAsync(IPAddress.Loopback, forwarder.LocalPort, Token);
            var stream = client.GetStream();
            await stream.WriteAsync("ping"u8.ToArray(), Token);
            var buffer = new byte[4];
            await stream.ReadExactlyAsync(buffer, Token);
            Assert.Equal("ping", Encoding.ASCII.GetString(buffer));
        }

        // The probe plus two relayed connections, each asking for the database by name.
        Assert.All(proxy.Targets, t => Assert.Equal("db.internal.test:5432", t));
        Assert.Equal(3, proxy.Targets.Count);
    }

    [Fact]
    public async Task WrongProxyPasswordFailsBeforeTheDriverDials()
    {
        using var echo = EchoServer.Start();
        await using var proxy = FakeProxy.Start(ProxyProtocol.Socks5, echo.Port, "me", "pwd");
        var settings = new ProxySettings { Enabled = true, Host = "127.0.0.1", Port = proxy.Port, Username = "me" };

        var error = await Assert.ThrowsAsync<TunnelException>(() => ProxyForwarder.StartAsync(Request("db", 1), settings, "nope", TimeSpan.FromSeconds(5), Token));

        Assert.Equal(TunnelFailureKind.ProxyAuthenticationFailed, error.Kind);
    }

    [Fact]
    public async Task ProxyThatRequiresAuthenticationSaysSo()
    {
        using var echo = EchoServer.Start();
        await using var proxy = FakeProxy.Start(ProxyProtocol.Socks5, echo.Port, "me", "pwd");
        var settings = new ProxySettings { Enabled = true, Host = "127.0.0.1", Port = proxy.Port };

        var error = await Assert.ThrowsAsync<TunnelException>(() => ProxyForwarder.StartAsync(Request("db", 1), settings, null, TimeSpan.FromSeconds(5), Token));

        Assert.Equal(TunnelFailureKind.ProxyAuthenticationFailed, error.Kind);
        Assert.Contains("requires a user name", error.Message, StringComparison.Ordinal);
    }

    [Fact]
    public async Task UnreachableProxyIsReportedAsSuch()
    {
        var settings = new ProxySettings { Enabled = true, Host = "127.0.0.1", Port = FreePort.Find() };

        var error = await Assert.ThrowsAsync<TunnelException>(() => ProxyForwarder.StartAsync(Request("db", 1), settings, null, TimeSpan.FromSeconds(5), Token));

        Assert.Equal(TunnelFailureKind.ProxyUnreachable, error.Kind);
    }

    [Fact]
    public void FixedPortsGetOneAttemptAndAutomaticOnesRetry()
    {
        var next = 40000;
        var automatic = new LocalPortPolicy(null, 5, () => next++);
        var fixedPort = new LocalPortPolicy(6543, 5);

        Assert.Equal(5, automatic.Attempts);
        Assert.Equal(40000, automatic.PortFor(1));
        Assert.Equal(40001, automatic.PortFor(2));
        Assert.True(automatic.RetriesAfter(4));
        Assert.False(automatic.RetriesAfter(5));
        Assert.Equal(1, fixedPort.Attempts);
        Assert.Equal(6543, fixedPort.PortFor(1));
        Assert.False(fixedPort.RetriesAfter(1));
        Assert.Throws<ArgumentOutOfRangeException>(() => new LocalPortPolicy(70000, 1));
        Assert.True(LocalPortPolicy.IsBindFailure("listen tcp 127.0.0.1:5432: bind: Only one usage of each socket address is normally permitted."));
    }

    [Fact]
    public void CloudSqlProxyArgumentsMatchTheMacCommandLine()
    {
        var settings = new CloudSqlProxySettings { InstanceConnectionName = " proj:us-central1:db ", UseIamAuth = true, UsePrivateIp = true, AuthMode = CloudSqlAuthMode.ServiceAccountKey };

        Assert.Equal(["--port", "50000", "--address", "127.0.0.1", "--auto-iam-authn", "--private-ip", "proj:us-central1:db"], HelperArguments.CloudSqlProxy(settings, 50000));
        Assert.Equal("{\"type\":\"service_account\"}", HelperArguments.CloudSqlProxyEnvironment(settings, " {\"type\":\"service_account\"} ")[HelperArguments.CloudSqlJsonCredentialsVariable]);
        Assert.Throws<TunnelException>(() => HelperArguments.CloudSqlProxyEnvironment(settings, null));
        Assert.Empty(HelperArguments.CloudSqlProxyEnvironment(settings with { AuthMode = CloudSqlAuthMode.ApplicationDefault }, null));
    }

    [Fact]
    public void CloudflaredArgumentsMatchTheMacCommandLine()
    {
        var settings = new CloudflareTunnelSettings { AccessHostname = "db.example.com", AuthMethod = CloudflareAuthMethod.ServiceToken };

        Assert.Equal(["access", "tcp", "--hostname", "db.example.com", "--url", "127.0.0.1:5000"], HelperArguments.Cloudflared(settings, 5000));
        Assert.Equal("0.0.0.0:5000", HelperArguments.Cloudflared(settings with { ExposeToLan = true }, 5000)[5]);
        var environment = HelperArguments.CloudflaredEnvironment(settings, "id", "secret");
        Assert.Equal("id", environment[HelperArguments.CloudflareTokenIdVariable]);
        Assert.Equal("secret", environment[HelperArguments.CloudflareTokenSecretVariable]);
        Assert.Throws<TunnelException>(() => HelperArguments.CloudflaredEnvironment(settings, "id", ""));
        Assert.Equal(["access", "login", "db.example.com"], HelperArguments.CloudflaredLogin(settings));
    }

    [Fact]
    public void CloudflaredBrowserPromptIsRecognised()
    {
        var output = "2026-10-28T10:00:00Z INF Start Websocket listener\n"
            + "Please open the following URL and log in with your Cloudflare account:\n"
            + "https://db.example.com/cdn-cgi/access/cli?redirect_url=x&token=abc \n";

        Assert.Equal(new Uri("https://db.example.com/cdn-cgi/access/cli?redirect_url=x&token=abc"), HelperArguments.CloudflaredSignInUri(output));
        Assert.Null(HelperArguments.CloudflaredSignInUri("INF Start Websocket listener host=127.0.0.1:5000"));
    }

    [Fact]
    public void LocatorFindsProgramsAndRefusesBatchScripts()
    {
        var bin = Directory.CreateDirectory(Path.Combine(_directory, "bin")).FullName;
        File.WriteAllText(Path.Combine(bin, "tool.exe"), string.Empty);
        File.WriteAllText(Path.Combine(bin, "script.cmd"), "@echo off");

        Assert.Equal(Path.Combine(bin, "tool.exe"), ExecutableLocator.Find("tool", pathVariable: bin));
        Assert.Equal(Path.Combine(bin, "tool.exe"), ExecutableLocator.Find("tool", [bin], pathVariable: string.Empty));
        Assert.Equal(Path.Combine(bin, "tool.exe"), ExecutableLocator.Find(Path.Combine(bin, "tool.exe")));
        Assert.Null(ExecutableLocator.Find("missing", pathVariable: bin));
        Assert.Throws<TunnelException>(() => ExecutableLocator.Find("script", pathVariable: bin));
        Assert.Throws<TunnelException>(() => ExecutableLocator.Find(Path.Combine(bin, "script.cmd")));
    }

    [Fact]
    public async Task TunnelCommandRunsWithItsPlaceholdersFilledAndDiesWithTheTunnel()
    {
        var profile = new ConnectionProfile
        {
            Name = "cmd",
            Engine = DatabaseEngine.PostgreSql,
            Host = "db.internal",
            Port = 5432,
            TunnelCommand = new TunnelCommandSettings
            {
                Enabled = true,
                Method = TunnelCommandMethod.Custom,
                Command = $"\"{FakeSsh}\" -N -L 127.0.0.1:{{port}}:{{host}}:{{remotePort}} -l ops bastion",
            },
        };
        var factory = new NetworkTunnelFactory();

        var tunnel = Assert.IsType<ProcessTunnel>(await factory.OpenAsync(ConnectionRequest.Direct(profile, null), new NetworkTunnelSecrets(), Token));
        var processId = tunnel.ProcessId;

        Assert.Equal("127.0.0.1", tunnel.Request.Host);
        Assert.Equal(tunnel.LocalPort, tunnel.Request.Port);
        Assert.True(tunnel.IsAlive);

        await tunnel.DisposeAsync();

        Assert.False(tunnel.IsAlive);
        Assert.Throws<ArgumentException>(() => System.Diagnostics.Process.GetProcessById(processId));
    }

    [Fact]
    public async Task TunnelCommandThatExitsEarlyReportsItsOutput()
    {
        var profile = new ConnectionProfile
        {
            Name = "cmd",
            Engine = DatabaseEngine.PostgreSql,
            TunnelCommand = new TunnelCommandSettings { Enabled = true, Method = TunnelCommandMethod.Custom, Command = $"\"{FakeSsh}\" -L 127.0.0.1:{{port}}:h:1 -l denied x" },
        };

        var error = await Assert.ThrowsAsync<TunnelException>(() => new NetworkTunnelFactory().OpenAsync(ConnectionRequest.Direct(profile, null), new NetworkTunnelSecrets(), Token));

        Assert.Equal(TunnelFailureKind.StartupFailed, error.Kind);
        Assert.Contains("Permission denied", error.Diagnostics, StringComparison.Ordinal);
    }

    [Fact]
    public async Task MissingHelpersAndBadSettingsAreReportedBeforeAnythingStarts()
    {
        var cloudflare = new ConnectionProfile
        {
            Name = "cf",
            Engine = DatabaseEngine.PostgreSql,
            CloudflareTunnel = new CloudflareTunnelSettings { Enabled = true, AccessHostname = "db.example.com", ExecutablePath = Path.Combine(_directory, "nope", "cloudflared.exe") },
        };
        var command = new ConnectionProfile
        {
            Name = "cmd",
            Engine = DatabaseEngine.PostgreSql,
            TunnelCommand = new TunnelCommandSettings { Enabled = true, Method = TunnelCommandMethod.Custom, Command = "ssh bastion" },
        };
        var factory = new NetworkTunnelFactory(new NetworkTunnelOptions { SearchPath = _directory });

        var notFound = await Assert.ThrowsAsync<TunnelException>(() => factory.OpenAsync(ConnectionRequest.Direct(cloudflare, null), new NetworkTunnelSecrets(), Token));
        var invalid = await Assert.ThrowsAsync<TunnelException>(() => factory.OpenAsync(ConnectionRequest.Direct(command, null), new NetworkTunnelSecrets(), Token));

        Assert.Equal(TunnelFailureKind.ExecutableNotFound, notFound.Kind);
        Assert.Equal(TunnelFailureKind.InvalidSettings, invalid.Kind);
        Assert.Contains("{port}", invalid.Message, StringComparison.Ordinal);
    }

    [Fact]
    public async Task AwsAccessKeySignInMintsAnRdsTokenForTheServerNotTheTunnel()
    {
        var provider = new CloudSignInTokenProvider(new FixedTime(new DateTimeOffset(2026, 10, 28, 9, 30, 0, TimeSpan.Zero)));
        var profile = new ConnectionProfile
        {
            Name = "rds",
            Engine = DatabaseEngine.PostgreSql,
            Host = "orders.abc.eu-west-1.rds.amazonaws.com",
            Username = "iam_app",
            Auth = new ConnectionAuthSettings { Method = SignInMethod.AwsIamAccessKey, AwsAccessKeyId = "AKIDEXAMPLE" },
        };

        var token = await provider.GetTokenAsync(profile, "secret", Token);

        Assert.StartsWith("orders.abc.eu-west-1.rds.amazonaws.com:5432/?Action=connect&DBUser=iam_app&", token, StringComparison.Ordinal);
        Assert.Contains("AKIDEXAMPLE%2F20261028%2Feu-west-1%2Frds-db%2Faws4_request", token, StringComparison.Ordinal);
        await Assert.ThrowsAsync<InvalidOperationException>(async () => await provider.GetTokenAsync(profile, null, Token));
        await Assert.ThrowsAsync<InvalidOperationException>(async () => await provider.GetTokenAsync(profile with { Username = null }, "secret", Token));
    }

    [Fact]
    public void ServicePrincipalWithoutTenantIsRefused()
    {
        var auth = new ConnectionAuthSettings { Method = SignInMethod.EntraId, EntraMode = EntraAuthMode.ServicePrincipal, EntraClientId = "c" };

        Assert.Throws<InvalidOperationException>(() => CloudSignInTokenProvider.CreateEntraCredential(auth, null, "secret"));
        Assert.IsType<Azure.Identity.ClientSecretCredential>(CloudSignInTokenProvider.CreateEntraCredential(auth with { EntraTenantId = "t" }, null, "secret"));
        Assert.IsType<Azure.Identity.ManagedIdentityCredential>(CloudSignInTokenProvider.CreateEntraCredential(auth with { EntraMode = EntraAuthMode.ManagedIdentity }, null, null));
    }

    private static ConnectionRequest Request(string host, int port) =>
        new(new ConnectionProfile { Name = "p", Engine = DatabaseEngine.PostgreSql, Host = host, Port = port }, null, host, port, null);

    private sealed class FixedTime(DateTimeOffset now) : TimeProvider
    {
        public override DateTimeOffset GetUtcNow() => now;
    }

    /// <summary>Echoes whatever each connection sends.</summary>
    private sealed class EchoServer : IDisposable
    {
        private readonly TcpListener _listener;

        private EchoServer(TcpListener listener)
        {
            _listener = listener;
            _ = AcceptAsync();
        }

        public int Port => ((IPEndPoint)_listener.LocalEndpoint).Port;

        public static EchoServer Start()
        {
            var listener = new TcpListener(IPAddress.Loopback, 0);
            listener.Start();
            return new EchoServer(listener);
        }

        public void Dispose() => _listener.Dispose();

        private async Task AcceptAsync()
        {
            try
            {
                while (true)
                {
                    var client = await _listener.AcceptTcpClientAsync();
                    _ = Task.Run(async () =>
                    {
                        using (client)
                        {
                            try
                            {
                                await client.GetStream().CopyToAsync(client.GetStream());
                            }
                            catch (IOException)
                            {
                            }
                        }
                    });
                }
            }
            catch (Exception ex) when (ex is SocketException or ObjectDisposedException)
            {
            }
        }
    }

    /// <summary>A SOCKS5 or HTTP CONNECT proxy that sends every target to one local port and records what was asked for.</summary>
    private sealed class FakeProxy : IAsyncDisposable
    {
        private readonly TcpListener _listener;
        private readonly ProxyProtocol _protocol;
        private readonly int _backendPort;
        private readonly string _user;
        private readonly string _password;
        private readonly Task _loop;

        private FakeProxy(TcpListener listener, ProxyProtocol protocol, int backendPort, string user, string password)
        {
            _listener = listener;
            _protocol = protocol;
            _backendPort = backendPort;
            _user = user;
            _password = password;
            _loop = AcceptAsync();
        }

        public int Port => ((IPEndPoint)_listener.LocalEndpoint).Port;

        public List<string> Targets { get; } = [];

        public static FakeProxy Start(ProxyProtocol protocol, int backendPort, string user, string password)
        {
            var listener = new TcpListener(IPAddress.Loopback, 0);
            listener.Start();
            return new FakeProxy(listener, protocol, backendPort, user, password);
        }

        public async ValueTask DisposeAsync()
        {
            _listener.Dispose();
            try
            {
                await _loop;
            }
            catch (Exception ex) when (ex is SocketException or ObjectDisposedException)
            {
            }
        }

        private async Task AcceptAsync()
        {
            try
            {
                while (true)
                {
                    var client = await _listener.AcceptTcpClientAsync();
                    _ = Task.Run(() => ServeAsync(client));
                }
            }
            catch (Exception ex) when (ex is SocketException or ObjectDisposedException)
            {
            }
        }

        private async Task ServeAsync(TcpClient client)
        {
            using (client)
            {
                try
                {
                    var stream = client.GetStream();
                    var target = _protocol == ProxyProtocol.Socks5 ? await SocksAsync(stream) : await HttpAsync(stream);
                    if (target is null)
                    {
                        return;
                    }

                    lock (Targets)
                    {
                        Targets.Add(target);
                    }

                    using var backend = new TcpClient();
                    await backend.ConnectAsync(IPAddress.Loopback, _backendPort);
                    var upstream = backend.GetStream();
                    await Task.WhenAny(stream.CopyToAsync(upstream), upstream.CopyToAsync(stream));
                }
                catch (IOException)
                {
                }
            }
        }

        private async Task<string?> SocksAsync(NetworkStream stream)
        {
            var head = new byte[2];
            await stream.ReadExactlyAsync(head);
            var methods = new byte[head[1]];
            await stream.ReadExactlyAsync(methods);
            if (!methods.Contains((byte)2))
            {
                await stream.WriteAsync(new byte[] { 5, 0xFF });
                return null;
            }

            await stream.WriteAsync(new byte[] { 5, 2 });
            var version = new byte[2];
            await stream.ReadExactlyAsync(version);
            var user = new byte[version[1]];
            await stream.ReadExactlyAsync(user);
            var passwordLength = new byte[1];
            await stream.ReadExactlyAsync(passwordLength);
            var password = new byte[passwordLength[0]];
            await stream.ReadExactlyAsync(password);
            var ok = Encoding.UTF8.GetString(user) == _user && Encoding.UTF8.GetString(password) == _password;
            await stream.WriteAsync(new byte[] { 1, ok ? (byte)0 : (byte)1 });
            if (!ok)
            {
                return null;
            }

            var request = new byte[5];
            await stream.ReadExactlyAsync(request);
            var name = new byte[request[4]];
            await stream.ReadExactlyAsync(name);
            var port = new byte[2];
            await stream.ReadExactlyAsync(port);
            await stream.WriteAsync(new byte[] { 5, 0, 0, 1, 127, 0, 0, 1, 0, 0 });
            return $"{Encoding.ASCII.GetString(name)}:{(port[0] << 8) | port[1]}";
        }

        private async Task<string?> HttpAsync(NetworkStream stream)
        {
            var header = new StringBuilder();
            var one = new byte[1];
            while (!header.ToString().EndsWith("\r\n\r\n", StringComparison.Ordinal))
            {
                await stream.ReadExactlyAsync(one);
                header.Append((char)one[0]);
            }

            var text = header.ToString();
            var expected = "Proxy-Authorization: Basic " + Convert.ToBase64String(Encoding.UTF8.GetBytes(_user + ":" + _password));
            if (!text.Contains(expected, StringComparison.Ordinal))
            {
                await stream.WriteAsync("HTTP/1.1 407 Proxy Authentication Required\r\n\r\n"u8.ToArray());
                return null;
            }

            await stream.WriteAsync("HTTP/1.1 200 Connection established\r\n\r\n"u8.ToArray());
            return text.Split(' ')[1];
        }
    }
}
