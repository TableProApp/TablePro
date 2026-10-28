using MongoDB.Driver;
using MongoDB.Driver.Core.Configuration;
using TablePro.Core.Connections;
using TablePro.Core.Drivers;

namespace TablePro.Drivers.MongoDb.Tests;

public sealed class ClientSettingsTests
{
    private static ConnectionRequest Request(
        string? user = "app",
        string? database = "shop",
        SslMode ssl = SslMode.Disabled,
        string host = "db.example.com",
        string dialHost = "127.0.0.1",
        int dialPort = 27999,
        Dictionary<string, string>? options = null,
        bool ssh = false)
    {
        var profile = new ConnectionProfile
        {
            Name = "test",
            Engine = DatabaseEngine.MongoDb,
            Host = host,
            Database = database,
            Username = user,
            SslMode = ssl,
            ConnectTimeoutSeconds = 7,
            AdditionalOptions = options ?? [],
            Ssh = ssh ? new SshTunnelSettings { Enabled = true, Host = "bastion" } : null,
        };
        return new ConnectionRequest(profile, "s3cret", dialHost, dialPort, database);
    }

    [Fact]
    public void DialsTheRequestEndpointDirectly()
    {
        var settings = MongoClientSettingsFactory.Build(Request());

        var server = Assert.Single(settings.Servers);
        Assert.Equal("127.0.0.1", server.Host);
        Assert.Equal(27999, server.Port);
        Assert.True(settings.DirectConnection);
        Assert.Equal("TablePro", settings.ApplicationName);
        Assert.Equal(TimeSpan.FromSeconds(7), settings.ConnectTimeout);
        Assert.Equal(TimeSpan.FromSeconds(7), settings.ServerSelectionTimeout);
        Assert.False(settings.RetryWrites);
        Assert.False(settings.UseTls);
    }

    [Fact]
    public void LogsInWithScramAgainstTheConnectionsDatabase()
    {
        var credential = MongoClientSettingsFactory.Build(Request()).Credential;

        Assert.Equal("app", credential.Username);
        Assert.Equal("shop", credential.Source);
        Assert.Null(credential.Mechanism);
    }

    [Theory]
    [InlineData(null, null, false, "admin")]
    [InlineData("shop", null, false, "shop")]
    [InlineData("shop", null, true, "admin")]
    [InlineData("shop", "users", false, "users")]
    [InlineData("shop", "users", true, "users")]
    public void ChoosesTheAuthenticationDatabase(string? database, string? authSource, bool srv, string expected)
    {
        var options = new Dictionary<string, string>();
        if (authSource is not null)
        {
            options["authSource"] = authSource;
        }

        var profile = Request(database: database, options: options).Profile;

        Assert.Equal(expected, MongoClientSettingsFactory.AuthSource(profile, srv));
    }

    [Fact]
    public void AnExternalMechanismLogsInAgainstExternal()
    {
        var request = Request(options: new() { ["authMechanism"] = "MONGODB-X509" });

        Assert.Equal("$external", MongoClientSettingsFactory.AuthSource(request.Profile, useSrv: false));
    }

    [Fact]
    public void NoUserConnectsWithoutALogin()
    {
        Assert.Null(MongoClientSettingsFactory.Build(Request(user: null)).Credential);
        Assert.Null(MongoClientSettingsFactory.Build(Request(user: "")).Credential);
    }

    [Fact]
    public void ASeedListUsesSrvAndTls()
    {
        var request = Request(host: "cluster0.example.net", dialHost: "cluster0.example.net", ssl: SslMode.Preferred, options: new() { ["srv"] = "true" });

        var settings = MongoClientSettingsFactory.Build(request);

        Assert.Equal(ConnectionStringScheme.MongoDBPlusSrv, settings.Scheme);
        Assert.Equal("cluster0.example.net", settings.Server.Host);
        Assert.False(settings.DirectConnection);
        Assert.True(settings.UseTls);
        Assert.Equal("admin", settings.Credential.Source);
    }

    [Fact]
    public void ASeedListIsRefusedThroughSsh()
    {
        var request = Request(options: new() { ["srv"] = "true" }, ssh: true);

        var error = Assert.Throws<InvalidOperationException>(() => MongoClientSettingsFactory.Build(request));
        Assert.Contains("SSH", error.Message, StringComparison.Ordinal);
    }

    [Fact]
    public void SeveralHostsSeedAReplicaSetWithoutDirectConnection()
    {
        var request = Request(host: "a.example.com:27017, b.example.com:27018,[::1]", dialHost: "a.example.com:27017, b.example.com:27018,[::1]", dialPort: 27017, options: new() { ["replicaSet"] = "rs0" });

        var settings = MongoClientSettingsFactory.Build(request);

        Assert.Equal(["a.example.com:27017", "b.example.com:27018", "[::1]:27017"], settings.Servers.Select(s => $"{s.Host}:{s.Port}"));
        Assert.False(settings.DirectConnection);
        Assert.Equal("rs0", settings.ReplicaSetName);
    }

    [Theory]
    [InlineData(SslMode.Disabled, false, false)]
    [InlineData(SslMode.Preferred, false, false)]
    [InlineData(SslMode.Required, true, true)]
    [InlineData(SslMode.VerifyCa, true, false)]
    [InlineData(SslMode.VerifyIdentity, true, false)]
    public void MapsEverySslMode(SslMode mode, bool tls, bool allowInsecure)
    {
        var settings = MongoClientSettingsFactory.Build(Request(ssl: mode, dialHost: "db.example.com"));

        Assert.Equal(tls, settings.UseTls);
        Assert.Equal(allowInsecure, settings.AllowInsecureTls);
        Assert.Equal(mode == SslMode.VerifyCa, settings.SslSettings?.ServerCertificateValidationCallback is not null);
    }

    [Fact]
    public void VerifyIdentityThroughATunnelChecksTheTypedHost()
    {
        var settings = MongoClientSettingsFactory.Build(Request(ssl: SslMode.VerifyIdentity, ssh: true));

        Assert.NotNull(settings.SslSettings?.ServerCertificateValidationCallback);
    }

    [Fact]
    public void AnExplicitMechanismIsUsed()
    {
        var credential = MongoClientSettingsFactory.Build(Request(options: new() { ["authMechanism"] = "SCRAM-SHA-256" })).Credential;

        Assert.Equal("SCRAM-SHA-256", credential.Mechanism);
    }

    [Fact]
    public void BuildingSettingsDialsNothing()
    {
        // A client is built from the settings at connect; until then nothing has touched the network.
        var settings = MongoClientSettingsFactory.Build(Request());

        Assert.IsType<MongoClientSettings>(settings);
        Assert.False(settings.IsFrozen);
    }
}
