using System.Data;
using System.Data.Common;
using Snowflake.Data.Client;
using TablePro.Core.Connections;
using TablePro.Core.Schema;
using TablePro.Core.Sql;
using TablePro.Drivers.Snowflake;

namespace TablePro.Drivers.Warehouse.Tests;

public sealed class SnowflakeTests
{
    private static DbConnectionStringBuilder Parse(SnowflakeConnectionSettings settings) => new() { ConnectionString = settings.ConnectionString };

    [Theory]
    [InlineData("xy12345.eu-central-1", "xy12345", "xy12345.eu-central-1.snowflakecomputing.com")]
    [InlineData("myorg-myaccount", "myorg-myaccount", "myorg-myaccount.snowflakecomputing.com")]
    [InlineData("XY12345.us-east-2.aws.snowflakecomputing.com", "XY12345", "xy12345.us-east-2.aws.snowflakecomputing.com")]
    [InlineData("https://myorg-acct.snowflakecomputing.com/console", "myorg-acct", "myorg-acct.snowflakecomputing.com")]
    [InlineData(" xy12345.eu-central-1.privatelink ", "xy12345", "xy12345.eu-central-1.privatelink.snowflakecomputing.com")]
    [InlineData("ab123.cn-north-1.snowflakecomputing.cn", "ab123", "ab123.cn-north-1.snowflakecomputing.cn")]
    public void ParsesEveryAccountSpelling(string text, string account, string host)
    {
        Assert.Equal(new SnowflakeAccount(account, host), SnowflakeAccount.Parse(text));
    }

    [Fact]
    public void EmptyAccountIsRefused()
    {
        Assert.Throws<ArgumentException>(() => SnowflakeAccount.Parse("  "));
    }

    [Fact]
    public void PasswordLoginKeepsThePasswordOutOfTheConnectionString()
    {
        var settings = SnowflakeConnectionFactory.Build(Profiles.Request(
            DatabaseEngine.Snowflake,
            host: "xy12345.eu-central-1",
            port: 443,
            database: "SALES",
            options: new Dictionary<string, string> { ["warehouse"] = "COMPUTE_WH", ["Role"] = "ANALYST", ["schema"] = "RAW" }));

        var builder = Parse(settings);
        Assert.Equal(SnowflakeAuthentication.Password, settings.Authentication);
        Assert.Equal("s3cret;'x", settings.Password);
        Assert.Equal("xy12345", builder["account"]);
        Assert.Equal("xy12345.eu-central-1.snowflakecomputing.com", builder["host"]);
        Assert.Equal("app", builder["user"]);
        Assert.Equal("SALES", builder["db"]);
        Assert.Equal("COMPUTE_WH", builder["warehouse"]);
        Assert.Equal("ANALYST", builder["role"]);
        Assert.Equal("RAW", builder["schema"]);
        Assert.Equal("7", builder["connection_timeout"]);
        Assert.Equal("Destroy", builder["changedsession"]);
        Assert.False(builder.ContainsKey("password"));
        Assert.False(builder.ContainsKey("port"));
        Assert.DoesNotContain("s3cret", settings.ToString(), StringComparison.Ordinal);
    }

    [Fact]
    public void PrivateKeyFileSwitchesToKeyPairWithThePasswordAsPassphrase()
    {
        var settings = SnowflakeConnectionFactory.Build(Profiles.Request(
            DatabaseEngine.Snowflake,
            host: "xy12345",
            password: "pass;phrase",
            filePath: @"C:\keys\rsa_key.p8"));

        var builder = Parse(settings);
        Assert.Equal(SnowflakeAuthentication.KeyPair, settings.Authentication);
        Assert.Null(settings.Password);
        Assert.Equal("snowflake_jwt", builder["authenticator"]);
        Assert.Equal(@"C:\keys\rsa_key.p8", builder["private_key_file"]);
        Assert.Equal("pass;phrase", builder["private_key_pwd"]);
    }

    [Fact]
    public void ExternalBrowserSendsNoSecret()
    {
        var settings = SnowflakeConnectionFactory.Build(Profiles.Request(
            DatabaseEngine.Snowflake,
            host: "xy12345",
            filePath: @"C:\keys\ignored.p8",
            options: new Dictionary<string, string> { ["authenticator"] = "externalbrowser" }));

        Assert.Equal(SnowflakeAuthentication.ExternalBrowser, settings.Authentication);
        Assert.Null(settings.Password);
        Assert.False(Parse(settings).ContainsKey("private_key_file"));
    }

    [Fact]
    public void OAuthSendsThePasswordAsTheToken()
    {
        var settings = SnowflakeConnectionFactory.Build(Profiles.Request(
            DatabaseEngine.Snowflake,
            host: "xy12345",
            password: "token-value",
            options: new Dictionary<string, string> { ["authenticator"] = "OAUTH" }));

        Assert.Equal(SnowflakeAuthentication.OAuth, settings.Authentication);
        Assert.Null(settings.Password);
        Assert.Equal("token-value", Parse(settings)["token"]);
    }

    [Fact]
    public void AccountOptionWinsOverHostAndAnOddPortIsKept()
    {
        var settings = SnowflakeConnectionFactory.Build(Profiles.Request(
            DatabaseEngine.Snowflake,
            host: "proxy.internal",
            port: 8443,
            options: new Dictionary<string, string> { ["account"] = "ab12345.us-west-2" }));

        var builder = Parse(settings);
        Assert.Equal("ab12345", builder["account"]);
        Assert.Equal("ab12345.us-west-2.snowflakecomputing.com", builder["host"]);
        Assert.Equal("8443", builder["port"]);
    }

    [Fact]
    public void BindingUsesPositionalNamesAndTypes()
    {
        using var connection = new SnowflakeDbConnection();
        var spec = new SqlCommandSpec("SELECT * FROM t WHERE a = :1 AND b = :2 AND c = :3", [new(":1", 5L), new(":2", "x"), new(":3", null)]);

        using var command = SnowflakeSession.Bind(connection, spec);

        Assert.Equal(["1", "2", "3"], command.Parameters.Cast<DbParameter>().Select(p => p.ParameterName));
        Assert.Equal(DbType.Int64, command.Parameters[0].DbType);
        Assert.Equal(DbType.String, command.Parameters[1].DbType);
        Assert.Equal(DBNull.Value, command.Parameters[2].Value);
    }

    [Fact]
    public void DefinitionsUseGetDdlWithRoutineArgumentTypes()
    {
        var path = SnowflakeSql.TablePath("SALES", new ObjectName("RAW", "add_tax"), "PUBLIC");

        Assert.Equal("\"SALES\".\"RAW\".\"add_tax\"", path);
        Assert.Equal(
            "SELECT GET_DDL('FUNCTION', '\"SALES\".\"RAW\".\"add_tax\"(NUMBER(38,0), VARCHAR)', TRUE)",
            SnowflakeSql.GetDdl(ObjectKind.Function, path, "ADD_TAX(NUMBER(38,0), VARCHAR) RETURN NUMBER(38,2)"));
        Assert.Equal("SELECT GET_DDL('VIEW', '\"S\".\"v\"', TRUE)", SnowflakeSql.GetDdl(ObjectKind.MaterializedView, "\"S\".\"v\"", null));
        Assert.Equal("()", SnowflakeSql.ArgumentTypes("NOW() RETURN TIMESTAMP_LTZ"));
    }

    [Fact]
    public void LiteralsEscapeBackslashesAndQuotes()
    {
        Assert.Equal("'a\\\\b''c'", SnowflakeSql.Literal("a\\b'c"));
    }
}
