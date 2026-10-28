using TablePro.Core.Connections;
using TablePro.Core.Drivers;

namespace TablePro.Core.Tests.Connections;

public sealed class TransportAndSignInTests
{
    private static ConnectionProfile Profile(DatabaseEngine engine = DatabaseEngine.PostgreSql) =>
        new() { Name = "p", Engine = engine, Host = "db.example.com" };

    [Fact]
    public void CloudSqlIsOfferedOnlyForTheEnginesCloudSqlHosts()
    {
        Assert.Contains(ConnectionTransport.CloudSqlProxy, ConnectionTransports.Available(DatabaseEngine.PostgreSql));
        Assert.Contains(ConnectionTransport.CloudSqlProxy, ConnectionTransports.Available(DatabaseEngine.SqlServer));
        Assert.DoesNotContain(ConnectionTransport.CloudSqlProxy, ConnectionTransports.Available(DatabaseEngine.Redis));
        Assert.Contains(ConnectionTransport.Proxy, ConnectionTransports.Available(DatabaseEngine.Redis));
        Assert.Equal([ConnectionTransport.Direct], ConnectionTransports.Available(DatabaseEngine.Sqlite));
    }

    [Fact]
    public void WithTransportTurnsOneOnAndKeepsTheOthersSettings()
    {
        var profile = Profile() with { Ssh = new SshTunnelSettings { Enabled = true, Host = "bastion" } };

        var proxied = profile.WithTransport(ConnectionTransport.Proxy);

        Assert.Equal(ConnectionTransport.Proxy, proxied.ActiveTransport());
        Assert.False(proxied.Ssh!.Enabled);
        Assert.Equal("bastion", proxied.Ssh.Host);
        Assert.Null(proxied.CloudSqlProxy);
        Assert.Equal(ConnectionTransport.Ssh, proxied.WithTransport(ConnectionTransport.Ssh).ActiveTransport());
        Assert.Equal(ConnectionTransport.Direct, proxied.WithTransport(ConnectionTransport.Direct).ActiveTransport());
    }

    [Fact]
    public void TwoTransportsAtOnceAreRefused()
    {
        var profile = Profile() with
        {
            Ssh = new SshTunnelSettings { Enabled = true, Host = "bastion" },
            Proxy = new ProxySettings { Enabled = true, Host = "proxy" },
        };

        Assert.Equal(ConnectionTransport.Direct, profile.ActiveTransport());
        Assert.Contains("only one connection method", profile.Validate(), StringComparison.Ordinal);
    }

    [Theory]
    [InlineData("", 1080, "Proxy host is required.")]
    [InlineData("proxy", 0, "Proxy port must be between 1 and 65535.")]
    [InlineData("proxy", 1080, null)]
    public void ProxySettingsAreValidated(string host, int port, string? expected)
    {
        var profile = Profile() with { Proxy = new ProxySettings { Enabled = true, Host = host, Port = port } };

        Assert.Equal(expected, profile.Validate());
    }

    [Theory]
    [InlineData("project:region:instance", true)]
    [InlineData("domain.com:project:region:instance", true)]
    [InlineData("project:instance", false)]
    [InlineData("project::instance", false)]
    [InlineData("", false)]
    public void InstanceConnectionNamesNeedThreeParts(string name, bool valid)
    {
        Assert.Equal(valid, ConnectionTransports.IsValidInstanceConnectionName(name));
    }

    [Fact]
    public void CloudSqlOnAnEngineItCannotServeIsRefused()
    {
        var profile = Profile(DatabaseEngine.Redis) with { CloudSqlProxy = new CloudSqlProxySettings { Enabled = true, InstanceConnectionName = "p:r:i" } };

        Assert.Contains("cannot connect through", profile.Validate(), StringComparison.Ordinal);
    }

    [Theory]
    [InlineData("ssh -N -L {port}:db:5432 bastion", new[] { "ssh", "-N", "-L", "{port}:db:5432", "bastion" })]
    [InlineData(@"C:\Tools\kubectl.exe port-forward", new[] { @"C:\Tools\kubectl.exe", "port-forward" })]
    [InlineData("\"C:\\Program Files\\x\\y.exe\" --a 'b c'", new[] { @"C:\Program Files\x\y.exe", "--a", "b c" })]
    [InlineData("say \"he said \\\"hi\\\"\"", new[] { "say", "he said \"hi\"" })]
    [InlineData("'single \\ \"literal\"'", new[] { "single \\ \"literal\"" })]
    [InlineData("a\t\tb\r\nc  ''", new[] { "a", "b", "c", "" })]
    public void CommandLinesSplitLikeWindows(string line, string[] expected)
    {
        Assert.Equal(expected, TunnelCommandLine.Tokenize(line));
    }

    [Fact]
    public void AnUnclosedQuoteIsAnError()
    {
        Assert.Throws<FormatException>(() => TunnelCommandLine.Tokenize("ssh \"bastion"));
        Assert.Equal("The command has an unclosed quote.", TunnelCommandLine.Validate(new TunnelCommandSettings { Method = TunnelCommandMethod.Custom, Command = "ssh 'x" }));
    }

    [Fact]
    public void PlaceholdersFillOneArgumentEachAndNeverSplit()
    {
        var settings = new TunnelCommandSettings { Method = TunnelCommandMethod.Custom, Command = "ssh -N -L 127.0.0.1:{localPort}:{host}:{remotePort} jump -p {port}" };

        var invocation = TunnelCommandLine.Build(settings, 50123, "evil host; rm -rf", 5432);

        Assert.Equal("ssh", invocation.Executable);
        Assert.Equal(["-N", "-L", "127.0.0.1:50123:evil host; rm -rf:5432", "jump", "-p", "50123"], invocation.Arguments);
    }

    [Theory]
    [InlineData("", "A command is required.")]
    [InlineData("ssh -L 1:{host}:2 bastion", "The command must contain {port}, where the local port goes.")]
    [InlineData("{port}", "The command must contain {port}, where the local port goes.")]
    [InlineData("ssh -L {port}:{host}:{remotePort} bastion", null)]
    public void CustomCommandsAreValidated(string command, string? expected)
    {
        Assert.Equal(expected, TunnelCommandLine.Validate(new TunnelCommandSettings { Method = TunnelCommandMethod.Custom, Command = command }));
    }

    [Fact]
    public void KubectlPresetMatchesTheMacCommand()
    {
        var settings = new TunnelCommandSettings
        {
            Method = TunnelCommandMethod.Kubectl,
            KubernetesResource = "service/postgres",
            KubernetesNamespace = "prod",
            KubernetesContext = "east",
        };

        var invocation = TunnelCommandLine.Build(settings, 50000, "ignored", 5432);

        Assert.Equal("kubectl", invocation.Executable);
        Assert.Equal(["--context=east", "--namespace=prod", "port-forward", "--address=127.0.0.1", "service/postgres", "50000:5432"], invocation.Arguments);
    }

    [Fact]
    public void AwsSsmPresetMatchesTheMacCommand()
    {
        var settings = new TunnelCommandSettings { Method = TunnelCommandMethod.AwsSsm, AwsTarget = "i-0abc", AwsProfile = "prod", AwsRegion = "eu-west-1", ExecutablePath = @"C:\aws\aws.exe" };

        var invocation = TunnelCommandLine.Build(settings, 50000, "db.internal", 5432);

        Assert.Equal(@"C:\aws\aws.exe", invocation.Executable);
        Assert.Equal(
            [
                "ssm", "start-session", "--target=i-0abc", "--document-name=AWS-StartPortForwardingSessionToRemoteHost",
                "--parameters=host=db.internal,portNumber=5432,localPortNumber=50000", "--profile=prod", "--region=eu-west-1",
            ],
            invocation.Arguments);
    }

    [Theory]
    [InlineData("--kubeconfig=/x")]
    [InlineData("service/a b")]
    public void PresetFieldsCannotSmuggleArguments(string resource)
    {
        var problem = TunnelCommandLine.Validate(new TunnelCommandSettings { Method = TunnelCommandMethod.Kubectl, KubernetesResource = resource });

        Assert.Equal("Resource cannot start with a dash or contain spaces.", problem);
    }

    [Fact]
    public void PreviewLeavesTheLocalPortAsAPlaceholderAndQuotesSpaces()
    {
        var settings = new TunnelCommandSettings { Method = TunnelCommandMethod.Custom, Command = "\"C:\\Program Files\\ssh.exe\" -L {port}:{host}:{remotePort} b" };

        Assert.Equal("\"C:\\Program Files\\ssh.exe\" -L {port}:db:5432 b", TunnelCommandLine.Preview(settings, "db", 5432));
    }

    [Fact]
    public void SignInMethodsFollowTheMacPickers()
    {
        Assert.Contains(SignInMethod.Kerberos, SignInMethods.Available(DatabaseEngine.PostgreSql));
        Assert.Contains(SignInMethod.Kerberos, SignInMethods.Available(DatabaseEngine.MariaDb));
        Assert.DoesNotContain(SignInMethod.Kerberos, SignInMethods.Available(DatabaseEngine.MySql));
        Assert.DoesNotContain(SignInMethod.EntraId, SignInMethods.Available(DatabaseEngine.MariaDb));
        Assert.Equal([SignInMethod.Password, SignInMethod.WindowsIntegrated, SignInMethod.EntraId], SignInMethods.Available(DatabaseEngine.SqlServer));
        Assert.Equal([SignInMethod.Password], SignInMethods.Available(DatabaseEngine.Redis));
        Assert.Contains(EntraAuthMode.Integrated, SignInMethods.EntraModes(DatabaseEngine.SqlServer));
        Assert.DoesNotContain(EntraAuthMode.Integrated, SignInMethods.EntraModes(DatabaseEngine.MySql));
    }

    [Fact]
    public void AMethodTheEngineDoesNotOfferFallsBackToThePassword()
    {
        var profile = Profile(DatabaseEngine.Redis) with { Auth = new ConnectionAuthSettings { Method = SignInMethod.Kerberos } };

        Assert.Equal(SignInMethod.Password, profile.EffectiveSignIn());
        Assert.False(profile.UsesSignInToken());
    }

    [Theory]
    [InlineData(DatabaseEngine.PostgreSql, SignInMethod.AwsIamProfile, EntraAuthMode.Interactive, true, false)]
    [InlineData(DatabaseEngine.PostgreSql, SignInMethod.AwsIamAccessKey, EntraAuthMode.Interactive, true, true)]
    [InlineData(DatabaseEngine.MySql, SignInMethod.EntraId, EntraAuthMode.Interactive, true, false)]
    [InlineData(DatabaseEngine.MySql, SignInMethod.EntraId, EntraAuthMode.ServicePrincipal, true, true)]
    [InlineData(DatabaseEngine.SqlServer, SignInMethod.EntraId, EntraAuthMode.ServicePrincipal, false, true)]
    [InlineData(DatabaseEngine.SqlServer, SignInMethod.WindowsIntegrated, EntraAuthMode.Interactive, false, false)]
    [InlineData(DatabaseEngine.PostgreSql, SignInMethod.Kerberos, EntraAuthMode.Interactive, false, false)]
    [InlineData(DatabaseEngine.PostgreSql, SignInMethod.Password, EntraAuthMode.Interactive, false, true)]
    public void WhatEachSignInNeeds(DatabaseEngine engine, SignInMethod method, EntraAuthMode mode, bool token, bool secret)
    {
        var profile = Profile(engine) with { Auth = new ConnectionAuthSettings { Method = method, EntraMode = mode } };

        Assert.Equal(token, profile.UsesSignInToken());
        Assert.Equal(secret, profile.UsesSecret());
    }

    [Fact]
    public void TokensRaiseTlsToRequiredExceptBehindTheCloudSqlProxy()
    {
        var iam = Profile() with { SslMode = SslMode.Preferred, Auth = new ConnectionAuthSettings { Method = SignInMethod.AwsIamProfile } };
        var proxied = iam with { CloudSqlProxy = new CloudSqlProxySettings { Enabled = true, InstanceConnectionName = "p:r:i" } };

        Assert.Equal(SslMode.Required, iam.EffectiveSslMode());
        Assert.Equal(SslMode.VerifyIdentity, (iam with { SslMode = SslMode.VerifyIdentity }).EffectiveSslMode());
        Assert.Equal(SslMode.Preferred, proxied.EffectiveSslMode());
        Assert.Equal(SslMode.Preferred, Profile().EffectiveSslMode());
    }

    [Fact]
    public void TunnelsTurnOffTlsForCloudSqlAndRelaxTheHostCheckElsewhere()
    {
        var verify = Profile() with { SslMode = SslMode.VerifyIdentity };
        var tunneled = new ConnectionRequest(verify, null, "127.0.0.1", 50000, null);
        var cloudSql = verify with { CloudSqlProxy = new CloudSqlProxySettings { Enabled = true, InstanceConnectionName = "p:r:i" } };

        Assert.Equal(SslMode.VerifyIdentity, ConnectionTls.SslModeFor(ConnectionRequest.Direct(verify, null)));
        Assert.Equal(SslMode.VerifyCa, ConnectionTls.SslModeFor(tunneled));
        Assert.Equal(SslMode.VerifyIdentity, ConnectionTls.SslModeFor(tunneled with { Profile = verify with { Engine = DatabaseEngine.SqlServer } }));
        Assert.Equal(SslMode.Disabled, ConnectionTls.SslModeFor(new ConnectionRequest(cloudSql, null, "127.0.0.1", 50000, null)));
    }

    [Fact]
    public void SigningKeyMatchesTheAwsDocumentationExample()
    {
        var key = AwsSigV4.SigningKey("wJalrXUtnFEMI/K7MDENG+bPxRfiCYEXAMPLEKEY", "20120215", "us-east-1", "iam");

        Assert.Equal("f4780e2d9f65fa895f9c67b32ce1baf0b0d8a43505a000a1a9e090d414db404d", AwsSigV4.Hex(key));
    }

    [Fact]
    public void PresignedQueryMatchesTheAwsQueryStringAuthExample()
    {
        var credentials = new AwsCredentialSet("AKIAIOSFODNN7EXAMPLE", "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY");

        var query = AwsSigV4.PresignQuery(
            "GET", "examplebucket.s3.amazonaws.com", "/test.txt", [], credentials, "us-east-1", "s3",
            new DateTimeOffset(2013, 5, 24, 0, 0, 0, TimeSpan.Zero), 86400, "UNSIGNED-PAYLOAD");

        Assert.Equal(
            "X-Amz-Algorithm=AWS4-HMAC-SHA256&X-Amz-Credential=AKIAIOSFODNN7EXAMPLE%2F20130524%2Fus-east-1%2Fs3%2Faws4_request"
            + "&X-Amz-Date=20130524T000000Z&X-Amz-Expires=86400&X-Amz-SignedHeaders=host"
            + "&X-Amz-Signature=aeeed9bbccd4d02ee5c0109b86d86835f995330da4c265957d157751f604d404",
            query);
    }

    [Fact]
    public void RdsTokenIsAPresignedConnectForTheEndpoint()
    {
        var token = RdsAuthToken.Generate(
            new AwsCredentialSet("AKID", "SECRET", "SESSION/TOKEN"),
            "MyDb.abc.us-east-1.rds.amazonaws.com",
            5432,
            "us-east-1",
            "iam_user",
            new DateTimeOffset(2026, 10, 28, 12, 0, 0, TimeSpan.Zero));

        Assert.StartsWith("mydb.abc.us-east-1.rds.amazonaws.com:5432/?Action=connect&DBUser=iam_user&X-Amz-Algorithm=AWS4-HMAC-SHA256", token, StringComparison.Ordinal);
        Assert.Contains("&X-Amz-Credential=AKID%2F20261028%2Fus-east-1%2Frds-db%2Faws4_request&", token, StringComparison.Ordinal);
        Assert.Contains("&X-Amz-Date=20261028T120000Z&X-Amz-Expires=900&X-Amz-Security-Token=SESSION%2FTOKEN&X-Amz-SignedHeaders=host&X-Amz-Signature=", token, StringComparison.Ordinal);
        Assert.DoesNotContain("https://", token, StringComparison.Ordinal);
        Assert.Matches("X-Amz-Signature=[0-9a-f]{64}$", token);
    }

    [Theory]
    [InlineData("db.abc123.eu-west-1.rds.amazonaws.com", "eu-west-1")]
    [InlineData("proxy-1.proxy-abc.us-east-2.rds.amazonaws.com", "us-east-2")]
    [InlineData("db.abc.cn-north-1.rds.amazonaws.com.cn", "cn-north-1")]
    [InlineData("db.example.com", null)]
    [InlineData("127.0.0.1", null)]
    public void RegionComesFromAnRdsHostName(string host, string? region)
    {
        Assert.Equal(region, RdsAuthToken.RegionFromHost(host));
    }

    [Fact]
    public void SigningEndpointPrefersTheOverrideAndOtherwiseTheProfileHost()
    {
        var profile = Profile() with { Host = "db.abc.us-east-1.rds.amazonaws.com", Port = 5433 };

        Assert.Equal(("db.abc.us-east-1.rds.amazonaws.com", 5433), RdsAuthToken.SigningEndpoint(profile));
        Assert.Equal(("real.rds.amazonaws.com", 6000), RdsAuthToken.SigningEndpoint(profile with { Auth = new ConnectionAuthSettings { AwsRdsEndpoint = "real.rds.amazonaws.com:6000" } }));
        Assert.Equal(("real", 5433), RdsAuthToken.SigningEndpoint(profile with { Auth = new ConnectionAuthSettings { AwsRdsEndpoint = "real" } }));
        Assert.Throws<FormatException>(() => RdsAuthToken.SigningEndpoint(profile with { Auth = new ConnectionAuthSettings { AwsRdsEndpoint = "real:x" } }));
        Assert.Throws<InvalidOperationException>(() => RdsAuthToken.SigningRegion(Profile(), "db.example.com"));
        Assert.Equal("ap-south-1", RdsAuthToken.SigningRegion(Profile() with { Auth = new ConnectionAuthSettings { AwsRegion = "ap-south-1" } }, "db.example.com"));
    }

    [Fact]
    public async Task TokensComeFromTheInstalledProvider()
    {
        var previous = SignInTokens.Provider;
        try
        {
            SignInTokens.Provider = new FixedProvider();
            var token = await SignInTokens.GetAsync(Profile(), "secret", TestContext.Current.CancellationToken);
            Assert.Equal("token-for-secret", token);

            SignInTokens.Provider = null;
            await Assert.ThrowsAsync<InvalidOperationException>(async () => await SignInTokens.GetAsync(Profile(), null, TestContext.Current.CancellationToken));
        }
        finally
        {
            SignInTokens.Provider = previous;
        }
    }

    private sealed class FixedProvider : ISignInTokenProvider
    {
        public ValueTask<string> GetTokenAsync(ConnectionProfile profile, string? secret, CancellationToken cancellationToken) =>
            ValueTask.FromResult("token-for-" + secret);
    }
}
