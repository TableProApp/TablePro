using System.Net.Security;
using System.Text;
using Cassandra;
using TablePro.Core.Connections;
using TablePro.Drivers.Cassandra;
using CoreSslMode = TablePro.Core.Connections.SslMode;

namespace TablePro.Drivers.WideColumn.Tests;

public sealed class CassandraConnectionTests
{
    [Fact]
    public void ReadsContactPointsDatacenterAndKeyspace()
    {
        var settings = CassandraConnectionSettings.From(Requests.For(
            DatabaseEngine.Cassandra,
            options: new Dictionary<string, string>
            {
                ["contactPoints"] = "10.0.0.2, 10.0.0.3,db.example.com",
                ["localDatacenter"] = "dc-east",
            }));

        Assert.Equal(["db.example.com", "10.0.0.2", "10.0.0.3"], settings.ContactPoints);
        Assert.Equal(9042, settings.Port);
        Assert.False(settings.IsTunneled);
        Assert.Equal("dc-east", settings.LocalDatacenter);
        Assert.Equal("shop", settings.Keyspace);
        Assert.Equal("app", settings.Username);
        Assert.Equal("s3cret", settings.Password);
        Assert.Equal(7000, settings.ConnectTimeoutMilliseconds);
    }

    [Fact]
    public void ATunnelDialsOnlyItsLocalEndAndChecksTheCertificateAgainstTheTypedHost()
    {
        var settings = CassandraConnectionSettings.From(Requests.For(
            DatabaseEngine.ScyllaDb,
            ssl: CoreSslMode.VerifyIdentity,
            options: new Dictionary<string, string> { ["contactPoints"] = "10.0.0.2" },
            dialHost: "127.0.0.1",
            dialPort: 49152));

        Assert.True(settings.IsTunneled);
        Assert.Equal(["127.0.0.1"], settings.ContactPoints);
        Assert.Equal(49152, settings.Port);
        Assert.Equal("db.example.com", settings.TlsHostName);
    }

    [Fact]
    public void DefaultsToLocalOneReadsAndLocalQuorumWrites()
    {
        var settings = CassandraConnectionSettings.From(Requests.For(DatabaseEngine.Cassandra));

        Assert.Equal(ConsistencyLevel.LocalOne, settings.ReadConsistency);
        Assert.Equal(ConsistencyLevel.LocalQuorum, settings.WriteConsistency);
    }

    [Fact]
    public void AConfiguredConsistencyAppliesToReadsAndWrites()
    {
        var settings = CassandraConnectionSettings.From(Requests.For(DatabaseEngine.Cassandra, options: new Dictionary<string, string> { ["consistency"] = "each_quorum" }));

        Assert.Equal(ConsistencyLevel.EachQuorum, settings.ReadConsistency);
        Assert.Equal(ConsistencyLevel.EachQuorum, settings.WriteConsistency);
    }

    [Theory]
    [InlineData("LOCAL_ONE", ConsistencyLevel.LocalOne)]
    [InlineData("quorum", ConsistencyLevel.Quorum)]
    [InlineData(" All ", ConsistencyLevel.All)]
    [InlineData("LocalQuorum", ConsistencyLevel.LocalQuorum)]
    public void ParsesConsistencyNames(string name, ConsistencyLevel expected) => Assert.Equal(expected, CassandraConnectionSettings.ParseConsistency(name));

    [Theory]
    [InlineData("SERIAL")]
    [InlineData("LOCAL_SERIAL")]
    [InlineData("FIVE")]
    [InlineData("3")]
    public void RefusesLevelsAConnectionCannotUse(string name) => Assert.Throws<ArgumentException>(() => CassandraConnectionSettings.ParseConsistency(name));

    [Fact]
    public void WritesConsistencyNamesAsCqlSpellsThem()
    {
        Assert.Equal("LOCAL_ONE", CassandraConnectionSettings.CqlName(ConsistencyLevel.LocalOne));
        Assert.Equal("EACH_QUORUM", CassandraConnectionSettings.CqlName(ConsistencyLevel.EachQuorum));
        Assert.Equal("QUORUM", CassandraConnectionSettings.CqlName(ConsistencyLevel.Quorum));
    }

    [Theory]
    [InlineData(CoreSslMode.Disabled, 9042, false)]
    [InlineData(CoreSslMode.Preferred, 9042, false)]
    [InlineData(CoreSslMode.Preferred, 9142, true)]
    [InlineData(CoreSslMode.Required, 9042, true)]
    [InlineData(CoreSslMode.VerifyCa, 9042, true)]
    [InlineData(CoreSslMode.VerifyIdentity, 9042, true)]
    public void DecidesTlsFromTheSslMode(CoreSslMode mode, int port, bool expected) =>
        Assert.Equal(expected, CassandraConnectionSettings.From(Requests.For(DatabaseEngine.Cassandra, port: port, ssl: mode)).UseTls);

    [Fact]
    public void PreferredUsesTlsForAmazonKeyspaces() =>
        Assert.True(CassandraConnectionSettings.From(Requests.For(DatabaseEngine.Cassandra, host: "cassandra.eu-west-1.amazonaws.com")).UseTls);

    [Fact]
    public void ChecksCertificatesAsStrictlyAsTheModeAsks()
    {
        static bool Accepts(CoreSslMode mode, SslPolicyErrors errors) =>
            CassandraConnectionSettings.From(Requests.For(DatabaseEngine.Cassandra, ssl: mode)).ValidateCertificate(new object(), null, null, errors);

        Assert.True(Accepts(CoreSslMode.Required, SslPolicyErrors.RemoteCertificateChainErrors));
        Assert.True(Accepts(CoreSslMode.VerifyCa, SslPolicyErrors.RemoteCertificateNameMismatch));
        Assert.False(Accepts(CoreSslMode.VerifyCa, SslPolicyErrors.RemoteCertificateChainErrors));
        Assert.False(Accepts(CoreSslMode.VerifyIdentity, SslPolicyErrors.RemoteCertificateNameMismatch));
        Assert.True(Accepts(CoreSslMode.VerifyIdentity, SslPolicyErrors.None));
    }

    [Theory]
    [InlineData("cassandra.us-east-1.amazonaws.com", true)]
    [InlineData("cassandra-fips.us-gov-west-1.amazonaws.com", true)]
    [InlineData("cassandra.cn-north-1.amazonaws.com.cn.", true)]
    [InlineData("vpce-1.cassandra.eu-west-1.vpce.amazonaws.com", true)]
    [InlineData("cassandra.example.com", false)]
    [InlineData("10.0.0.1", false)]
    public void RecognizesAmazonKeyspacesEndpoints(string host, bool expected) => Assert.Equal(expected, CassandraConnectionSettings.IsKeyspacesEndpoint(host));

    [Fact]
    public void SigV4TakesTheRegionFromTheEndpointAndTheKeysFromTheLogin()
    {
        var settings = CassandraConnectionSettings.From(Requests.For(
            DatabaseEngine.Cassandra,
            host: "cassandra.ap-south-1.amazonaws.com",
            port: 9142,
            user: "AKIDEXAMPLE",
            password: "secret",
            ssl: CoreSslMode.Required,
            options: new Dictionary<string, string> { ["awsAuth"] = "accessKey", ["awsSessionToken"] = "token" }));

        Assert.Equal(new KeyspacesCredentials("AKIDEXAMPLE", "secret", "token", "ap-south-1"), settings.SigV4);
        Assert.DoesNotContain("secret", settings.SigV4!.ToString(), StringComparison.Ordinal);
    }

    [Fact]
    public void SigV4RefusesPlainText() =>
        Assert.Throws<InvalidOperationException>(() => CassandraConnectionSettings.From(Requests.For(
            DatabaseEngine.Cassandra,
            ssl: CoreSslMode.Disabled,
            options: new Dictionary<string, string> { ["awsAuth"] = "accessKey", ["awsRegion"] = "us-east-1" })));

    [Fact]
    public void ReadsTheAllowFilteringOptIn()
    {
        Assert.False(CassandraConnectionSettings.From(Requests.For(DatabaseEngine.Cassandra)).AllowFiltering);
        Assert.True(CassandraConnectionSettings.From(Requests.For(DatabaseEngine.Cassandra, options: new Dictionary<string, string> { ["allowFiltering"] = "TRUE" })).AllowFiltering);
    }

    [Fact]
    public void BuildsAClusterWithTheChosenPolicies()
    {
        var settings = CassandraConnectionSettings.From(Requests.For(
            DatabaseEngine.Cassandra,
            host: "127.0.0.1",
            user: null,
            options: new Dictionary<string, string> { ["localDatacenter"] = "dc1", ["consistency"] = "QUORUM" }));

        using var cluster = settings.CreateBuilder().Build();

        Assert.Equal(ConsistencyLevel.Quorum, cluster.Configuration.QueryOptions.GetConsistencyLevel());
        Assert.IsType<DefaultLoadBalancingPolicy>(cluster.Configuration.Policies.LoadBalancingPolicy);
        Assert.Equal(9042, cluster.Configuration.ProtocolOptions.Port);
    }

    [Fact]
    public void ATunneledClusterKeepsToTheTunnelEnd()
    {
        var settings = CassandraConnectionSettings.From(Requests.For(DatabaseEngine.Cassandra, dialHost: "127.0.0.1", dialPort: 49152));

        using var cluster = settings.CreateBuilder().Build();

        Assert.IsNotType<DefaultLoadBalancingPolicy>(cluster.Configuration.Policies.LoadBalancingPolicy);
    }

    [Fact]
    public void SigV4StartsWithItsMechanismName()
    {
        Assert.Equal([0x53, 0x69, 0x67, 0x56, 0x34, 0x00, 0x00], KeyspacesSigV4.InitialResponse.ToArray());
    }

    [Fact]
    public void SigV4ExtractsTheNonce()
    {
        var nonce = Enumerable.Range(0, 32).Select(i => (byte)('a' + (i % 26))).ToArray();
        byte[] challenge = [.. "nonce="u8, .. nonce, .. ",foo=bar"u8];

        Assert.Equal(nonce, KeyspacesSigV4.Nonce(challenge));
        Assert.Null(KeyspacesSigV4.Nonce("hello"u8));
        Assert.Null(KeyspacesSigV4.Nonce([.. "nonce="u8, 1, 2, 3]));
    }

    [Fact]
    public void SigV4SignsTheNonceWithTheDateAndScope()
    {
        var credentials = new KeyspacesCredentials("AKIDEXAMPLE", "wJalrXUtnFEMI/K7MDENG+bPxRfiCYEXAMPLEKEY", null, "us-east-1");
        var now = DateTimeOffset.FromUnixTimeSeconds(1_440_938_160);
        var nonce = Enumerable.Range(0, 32).Select(i => (byte)i).ToArray();

        var response = KeyspacesSigV4.AuthResponse(nonce, credentials, now);
        var fields = response.Split(',').Select(p => p.Split('=', 2)).ToDictionary(p => p[0], p => p[1]);

        Assert.Equal("AKIDEXAMPLE", fields["access_key"]);
        Assert.Equal("20150830T123600Z", fields["amzdate"]);
        Assert.Matches("^[0-9a-f]{64}$", fields["signature"]);
        Assert.False(fields.ContainsKey("session_token"));
        Assert.Equal(response, KeyspacesSigV4.AuthResponse(nonce, credentials, now));
        Assert.NotEqual(response, KeyspacesSigV4.AuthResponse(nonce, credentials with { Region = "eu-west-1" }, now));
    }

    [Fact]
    public void SigV4AddsASessionTokenForTemporaryCredentials()
    {
        var response = KeyspacesSigV4.AuthResponse(new byte[32], new KeyspacesCredentials("ASIA", "secret", "TEMP", "eu-west-1"), DateTimeOffset.UnixEpoch);

        Assert.EndsWith(",session_token=TEMP", response, StringComparison.Ordinal);
    }

    [Fact]
    public void SigV4CanonicalRequestIsAPutToAuthenticate()
    {
        var canonical = KeyspacesSigV4.CanonicalRequest(Encoding.UTF8.GetBytes("abc"), "AK/20150830/us-east-1/cassandra/aws4_request", "20150830T123600Z");

        Assert.Equal(
            "PUT\n/authenticate\nX-Amz-Algorithm=AWS4-HMAC-SHA256&X-Amz-Credential=AK%2F20150830%2Fus-east-1%2Fcassandra%2Faws4_request"
            + "&X-Amz-Date=20150830T123600Z&X-Amz-Expires=900\nhost:cassandra\n\nhost\nba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad",
            canonical);
        Assert.Equal("a%20b~c%2B", KeyspacesSigV4.UriEncode("a b~c+"));
    }
}
