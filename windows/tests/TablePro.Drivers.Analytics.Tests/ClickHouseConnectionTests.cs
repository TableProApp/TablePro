using System.Net.Security;
using ClickHouse.Client.ADO;
using TablePro.Core.Connections;
using TablePro.Drivers.ClickHouse;

namespace TablePro.Drivers.Analytics.Tests;

public sealed class ClickHouseConnectionTests
{
    private static ClickHouseConnectionStringBuilder Parse(string connectionString) => new(connectionString);

    [Fact]
    public void ConnectionStringDialsTheTunnelWithCompressionAndSessions()
    {
        var builder = Parse(ClickHouseConnectionStringFactory.Build(Profiles.Tunnelled(DatabaseEngine.ClickHouse), []));

        Assert.Equal("127.0.0.1", builder.Host);
        Assert.Equal(15432, builder.Port);
        Assert.Equal("http", builder.Protocol);
        Assert.Equal("shop", builder.Database);
        Assert.Equal("app", builder.Username);
        Assert.Equal(Profiles.Password, builder.Password);
        Assert.True(builder.Compression);
        Assert.True(builder.UseSession);
        Assert.False(builder.ContainsKey("set_readonly"));
    }

    [Theory]
    [InlineData(SslMode.Disabled, "http", 8123)]
    [InlineData(SslMode.Preferred, "http", 8123)]
    [InlineData(SslMode.Required, "https", 8443)]
    [InlineData(SslMode.VerifyCa, "https", 8443)]
    [InlineData(SslMode.VerifyIdentity, "https", 8443)]
    public void DefaultPortAndProtocolFollowEverySslMode(SslMode mode, string protocol, int port)
    {
        var request = Profiles.Direct(Profiles.Profile(DatabaseEngine.ClickHouse, ssl: mode));

        var builder = Parse(ClickHouseConnectionStringFactory.Build(request, []));

        Assert.Equal(protocol, builder.Protocol);
        Assert.Equal(port, builder.Port);
        Assert.Equal("db.example.com", builder.Host);
    }

    [Theory]
    [InlineData(SslMode.Disabled)]
    [InlineData(SslMode.VerifyIdentity)]
    public void TypedPortWinsOverTheTlsDefault(SslMode mode)
    {
        var request = Profiles.Direct(Profiles.Profile(DatabaseEngine.ClickHouse, ssl: mode, port: 9440));

        Assert.Equal(9440, ClickHouseConnectionStringFactory.ResolvePort(request));
    }

    [Fact]
    public void TunnelPortWinsOverTheTlsDefault()
    {
        var request = Profiles.Tunnelled(DatabaseEngine.ClickHouse, ssl: SslMode.Required);

        Assert.Equal(15432, ClickHouseConnectionStringFactory.ResolvePort(request));
        Assert.Equal("https", Parse(ClickHouseConnectionStringFactory.Build(request, [])).Protocol);
    }

    [Fact]
    public void EmptyDatabaseAndUserFallBackToDefault()
    {
        var builder = Parse(ClickHouseConnectionStringFactory.Build(Profiles.Tunnelled(DatabaseEngine.ClickHouse, user: null, database: null), []));

        Assert.Equal("default", builder.Database);
        Assert.Equal("default", builder.Username);
    }

    [Fact]
    public void ReadOnlyProfileSendsReadonlySettings()
    {
        var builder = Parse(ClickHouseConnectionStringFactory.Build(Profiles.Tunnelled(DatabaseEngine.ClickHouse, safeMode: SafeModeLevel.ReadOnly), []));

        Assert.Equal("2", builder["set_readonly"]);
        Assert.Equal("0", builder["set_allow_ddl"]);
    }

    [Fact]
    public void StartupSettingsBecomeRequestSettings()
    {
        var builder = Parse(ClickHouseConnectionStringFactory.Build(
            Profiles.Tunnelled(DatabaseEngine.ClickHouse),
            [new("max_threads", "4"), new("join_use_nulls", "1")]));

        Assert.Equal("4", builder["set_max_threads"]);
        Assert.Equal("1", builder["set_join_use_nulls"]);
    }

    [Fact]
    public void AdditionalOptionsOverrideDefaults()
    {
        var options = new Dictionary<string, string> { ["Compression"] = "false", ["set_max_execution_time"] = "30" };

        var builder = Parse(ClickHouseConnectionStringFactory.Build(Profiles.Tunnelled(DatabaseEngine.ClickHouse, options: options), []));

        Assert.False(builder.Compression);
        Assert.Equal("30", builder["set_max_execution_time"]);
    }

    [Theory]
    [InlineData(SslMode.Required, SslPolicyErrors.RemoteCertificateChainErrors, true)]
    [InlineData(SslMode.Required, SslPolicyErrors.RemoteCertificateNameMismatch, true)]
    [InlineData(SslMode.VerifyCa, SslPolicyErrors.RemoteCertificateNameMismatch, true)]
    [InlineData(SslMode.VerifyCa, SslPolicyErrors.RemoteCertificateChainErrors, false)]
    [InlineData(SslMode.VerifyIdentity, SslPolicyErrors.RemoteCertificateNameMismatch, false)]
    [InlineData(SslMode.VerifyIdentity, SslPolicyErrors.None, true)]
    public void CertificateCheckFollowsTheMode(SslMode mode, SslPolicyErrors errors, bool accepted)
    {
        Assert.Equal(accepted, ClickHouseConnectionStringFactory.AcceptsCertificate(mode, errors));
    }

    [Theory]
    [InlineData(SslMode.Disabled, false)]
    [InlineData(SslMode.Preferred, false)]
    [InlineData(SslMode.Required, true)]
    [InlineData(SslMode.VerifyCa, true)]
    [InlineData(SslMode.VerifyIdentity, false)]
    public void HandlerReplacesCertificateValidationOnlyWhereTheModeRelaxesIt(SslMode mode, bool hasCallback)
    {
        using var handler = ClickHouseConnectionStringFactory.CreateHandler(Profiles.Profile(DatabaseEngine.ClickHouse, ssl: mode));

        Assert.Equal(hasCallback, handler.SslOptions.RemoteCertificateValidationCallback is not null);
        Assert.Equal(TimeSpan.FromSeconds(7), handler.ConnectTimeout);
        Assert.Equal(TimeSpan.FromSeconds(2), handler.PooledConnectionIdleTimeout);
    }

    [Fact]
    public void StartupSetStatementsAreParsedAndOthersKept()
    {
        var commands = ClickHouseStartup.Parse("SET max_threads = 4, log_comment = 'it''s';\nCREATE TEMPORARY TABLE t (x UInt8);\nset join_use_nulls=1");

        Assert.Equal(
            [new("max_threads", "4"), new("log_comment", "it's"), new("join_use_nulls", "1")],
            commands.Settings);
        Assert.Equal(["CREATE TEMPORARY TABLE t (x UInt8)"], commands.Statements);
    }

    [Theory]
    [InlineData("SETTINGS x = 1")]
    [InlineData("SET x")]
    [InlineData("SET a-b = 1")]
    [InlineData("SET ROLE admin")]
    public void NonSettingStatementsAreNotParsedAsSettings(string statement)
    {
        var settings = new List<KeyValuePair<string, string>>();

        Assert.False(ClickHouseStartup.TryParseSet(statement, settings));
        Assert.Empty(settings);
    }

    [Fact]
    public void EmptyStartupHasNothing()
    {
        var commands = ClickHouseStartup.Parse("  ");

        Assert.Empty(commands.Settings);
        Assert.Empty(commands.Statements);
    }
}
