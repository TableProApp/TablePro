using System.Net;
using System.Net.Security;
using TablePro.Core.Connections;
using TablePro.Core.Drivers;

namespace TablePro.Drivers.Redis.Tests;

public sealed class RedisConnectionOptionsTests
{
    private static ConnectionProfile Profile(Func<ConnectionProfile, ConnectionProfile>? change = null)
    {
        var profile = new ConnectionProfile { Name = "cache", Engine = DatabaseEngine.Redis, Host = "cache.example.com" };
        return change is null ? profile : change(profile);
    }

    private static (string Host, int Port) Single(EndPoint endpoint) => endpoint switch
    {
        DnsEndPoint dns => (dns.Host, dns.Port),
        IPEndPoint ip => (ip.Address.ToString(), ip.Port),
        _ => throw new InvalidOperationException(endpoint.ToString()),
    };

    [Fact]
    public void DialsTheRequestedHostAndPort()
    {
        var request = new ConnectionRequest(Profile(), null, "127.0.0.1", 51234, null);

        var options = RedisConnectionOptions.Build(request);

        Assert.Equal(("127.0.0.1", 51234), Single(Assert.Single(options.EndPoints)));
    }

    [Fact]
    public void DirectRequestUsesTheDefaultPort()
    {
        var options = RedisConnectionOptions.Build(ConnectionRequest.Direct(Profile(), null));

        Assert.Equal(("cache.example.com", 6379), Single(Assert.Single(options.EndPoints)));
    }

    [Fact]
    public void PasswordAloneLogsInAsTheDefaultUser()
    {
        var options = RedisConnectionOptions.Build(ConnectionRequest.Direct(Profile(), "s3cret"));

        Assert.Equal("s3cret", options.Password);
        Assert.Null(options.User);
    }

    [Fact]
    public void UsernameIsTheAclUser()
    {
        var options = RedisConnectionOptions.Build(ConnectionRequest.Direct(Profile(p => p with { Username = " reader " }), "pw"));

        Assert.Equal("reader", options.User);
    }

    [Fact]
    public void EmptyPasswordSendsNone()
    {
        var options = RedisConnectionOptions.Build(ConnectionRequest.Direct(Profile(), string.Empty));

        Assert.Null(options.Password);
    }

    [Theory]
    [InlineData(null, 0)]
    [InlineData("", 0)]
    [InlineData("4", 4)]
    [InlineData("db7", 7)]
    [InlineData("DB2", 2)]
    public void SelectsTheProfileDatabase(string? database, int expected)
    {
        var options = RedisConnectionOptions.Build(ConnectionRequest.Direct(Profile(p => p with { Database = database }), null));

        Assert.Equal(expected, options.DefaultDatabase);
    }

    [Fact]
    public void RefusesADatabaseThatIsNotANumber()
    {
        Assert.Throws<ArgumentException>(() => RedisConnectionOptions.Build(ConnectionRequest.Direct(Profile(p => p with { Database = "sessions" }), null)));
    }

    [Fact]
    public void ConnectTimeoutIsInMilliseconds()
    {
        var options = RedisConnectionOptions.Build(ConnectionRequest.Direct(Profile(p => p with { ConnectTimeoutSeconds = 7 }), null));

        Assert.Equal(7000, options.ConnectTimeout);
        Assert.True(options.AbortOnConnectFail);
    }

    [Fact]
    public void AllowsAdminCommandsAndNamesTheClient()
    {
        var options = RedisConnectionOptions.Build(ConnectionRequest.Direct(Profile(), null));

        Assert.True(options.AllowAdmin);
        Assert.Equal("TablePro", options.ClientName);
    }

    [Theory]
    [InlineData(SslMode.Disabled, false)]
    [InlineData(SslMode.Preferred, false)]
    [InlineData(SslMode.Required, true)]
    [InlineData(SslMode.VerifyCa, true)]
    [InlineData(SslMode.VerifyIdentity, true)]
    public void TlsFollowsTheSslMode(SslMode mode, bool tls)
    {
        var options = RedisConnectionOptions.Build(ConnectionRequest.Direct(Profile(p => p with { SslMode = mode }), null));

        Assert.Equal(tls, options.Ssl);
    }

    [Fact]
    public void TlsThroughATunnelChecksTheTypedHost()
    {
        var request = new ConnectionRequest(Profile(p => p with { SslMode = SslMode.VerifyIdentity }), null, "127.0.0.1", 40000, null);

        var options = RedisConnectionOptions.Build(request);

        Assert.Equal("cache.example.com", options.SslHost);
    }

    [Theory]
    [InlineData(SslMode.Required, SslPolicyErrors.RemoteCertificateChainErrors, true)]
    [InlineData(SslMode.VerifyCa, SslPolicyErrors.RemoteCertificateNameMismatch, true)]
    [InlineData(SslMode.VerifyCa, SslPolicyErrors.RemoteCertificateChainErrors, false)]
    [InlineData(SslMode.VerifyIdentity, SslPolicyErrors.RemoteCertificateNameMismatch, false)]
    [InlineData(SslMode.VerifyIdentity, SslPolicyErrors.None, true)]
    public void CertificateCheckFollowsTheSslMode(SslMode mode, SslPolicyErrors errors, bool accepted)
    {
        Assert.Equal(accepted, RedisConnectionOptions.AcceptsCertificate(mode, errors));
    }

    [Fact]
    public void AdditionalOptionsPassThrough()
    {
        var profile = Profile(p => p with { AdditionalOptions = new Dictionary<string, string> { ["syncTimeout"] = "9000", ["keepAlive"] = "30" } });

        var options = RedisConnectionOptions.Build(ConnectionRequest.Direct(profile, null));

        Assert.Equal(9000, options.SyncTimeout);
        Assert.Equal(30, options.KeepAlive);
    }

    [Fact]
    public void FormFieldsWinOverAdditionalOptions()
    {
        var profile = Profile(p => p with
        {
            Database = "2",
            AdditionalOptions = new Dictionary<string, string> { ["defaultDatabase"] = "9", ["password"] = "other", ["name"] = "custom" },
        });

        var options = RedisConnectionOptions.Build(ConnectionRequest.Direct(profile, "mine"));

        Assert.Equal(2, options.DefaultDatabase);
        Assert.Equal("mine", options.Password);
        Assert.Equal("custom", options.ClientName);
    }

    [Theory]
    [InlineData("db0", true, 0)]
    [InlineData("db15", true, 15)]
    [InlineData("3", true, 3)]
    [InlineData("db", false, 0)]
    [InlineData("db-1", false, 0)]
    [InlineData("public", false, 0)]
    [InlineData(null, false, 0)]
    public void ParsesSchemaNames(string? text, bool ok, int expected)
    {
        Assert.Equal(ok, RedisConnectionOptions.TryParseDatabaseIndex(text, out var index));
        Assert.Equal(expected, index);
    }

    [Fact]
    public void NamesSchemasAfterTheDatabaseNumber() => Assert.Equal("db12", RedisConnectionOptions.SchemaName(12));
}
