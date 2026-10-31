using Microsoft.Data.SqlClient;
using MySqlConnector;
using Npgsql;
using TablePro.Core.Connections;
using TablePro.Core.Drivers;
using TablePro.Drivers.MySql;
using TablePro.Drivers.PostgreSql;
using TablePro.Drivers.SqlServer;
using GssEncryptionMode = TablePro.Core.Connections.GssEncryptionMode;
using SslMode = TablePro.Core.Connections.SslMode;

namespace TablePro.Drivers.Tests;

/// <summary>How Kerberos, IAM and Entra sign-ins and the tunnels shape each engine's connection string.</summary>
public sealed class SignInConnectionStringTests
{
    private static ConnectionRequest Direct(DatabaseEngine engine, ConnectionAuthSettings? auth, SslMode ssl = SslMode.Preferred, string? user = "app") =>
        ConnectionRequest.Direct(
            new ConnectionProfile { Name = "t", Engine = engine, Host = "db.example.com", Username = user, SslMode = ssl, Auth = auth },
            "saved-secret");

    [Fact]
    public void PostgreSqlKerberosSendsNoPasswordAndSetsGssOptions()
    {
        var request = Direct(DatabaseEngine.PostgreSql, new ConnectionAuthSettings { Method = SignInMethod.Kerberos, KerberosServiceName = "pgsvc", GssEncryption = GssEncryptionMode.Require }, user: null);

        var builder = new NpgsqlConnectionStringBuilder(PostgreSqlConnectionStringFactory.Build(request));

        Assert.Null(builder.Password);
        Assert.Null(builder.Username);
        Assert.Equal("pgsvc", builder.KerberosServiceName);
        Assert.Equal(Npgsql.GssEncryptionMode.Require, builder.GssEncryptionMode);
    }

    [Fact]
    public void PostgreSqlIamLeavesThePasswordToTheProviderAndRequiresTls()
    {
        var request = Direct(DatabaseEngine.PostgreSql, new ConnectionAuthSettings { Method = SignInMethod.AwsIamProfile });

        var builder = new NpgsqlConnectionStringBuilder(PostgreSqlConnectionStringFactory.Build(request));

        Assert.Null(builder.Password);
        Assert.Equal("app", builder.Username);
        Assert.Equal(Npgsql.SslMode.Require, builder.SslMode);
    }

    [Fact]
    public void PostgreSqlBehindTheCloudSqlProxyTurnsTlsOff()
    {
        var profile = new ConnectionProfile
        {
            Name = "t",
            Engine = DatabaseEngine.PostgreSql,
            Host = "db",
            SslMode = SslMode.Required,
            CloudSqlProxy = new CloudSqlProxySettings { Enabled = true, InstanceConnectionName = "p:r:i" },
        };

        var builder = new NpgsqlConnectionStringBuilder(PostgreSqlConnectionStringFactory.Build(new ConnectionRequest(profile, "x", "127.0.0.1", 50000, null)));

        Assert.Equal(Npgsql.SslMode.Disable, builder.SslMode);
        Assert.Equal("127.0.0.1", builder.Host);
        Assert.Equal(50000, builder.Port);
    }

    [Fact]
    public void MySqlTokenSignInRequiresTlsForTheCleartextPlugin()
    {
        var request = Direct(DatabaseEngine.MySql, new ConnectionAuthSettings { Method = SignInMethod.EntraId });

        var builder = new MySqlConnectionStringBuilder(MySqlConnectionStringFactory.Build(request));

        Assert.Equal(string.Empty, builder.Password);
        Assert.Equal(MySqlSslMode.Required, builder.SslMode);
    }

    [Fact]
    public void MariaDbKerberosSendsNoPasswordAndNamesTheServerPrincipal()
    {
        var request = Direct(DatabaseEngine.MariaDb, new ConnectionAuthSettings { Method = SignInMethod.Kerberos, KerberosServiceName = "mariadb/db.example.com@EXAMPLE.COM" });

        var builder = new MySqlConnectionStringBuilder(MySqlConnectionStringFactory.Build(request));

        Assert.Equal(string.Empty, builder.Password);
        Assert.Equal("mariadb/db.example.com@EXAMPLE.COM", builder.ServerSPN);
    }

    [Fact]
    public void MySqlIgnoresKerberosSinceItsPluginIsMariaDbs()
    {
        var request = Direct(DatabaseEngine.MySql, new ConnectionAuthSettings { Method = SignInMethod.Kerberos });

        var builder = new MySqlConnectionStringBuilder(MySqlConnectionStringFactory.Build(request));

        Assert.Equal("saved-secret", builder.Password);
    }

    [Fact]
    public void SqlServerWindowsAuthenticationNamesTheServerSpnBehindATunnel()
    {
        var profile = new ConnectionProfile { Name = "t", Engine = DatabaseEngine.SqlServer, Host = "sql.corp.example.com", Username = "ignored", Auth = new ConnectionAuthSettings { Method = SignInMethod.WindowsIntegrated } };

        var direct = new SqlConnectionStringBuilder(SqlServerConnectionStringFactory.Build(ConnectionRequest.Direct(profile, null)));
        var tunneled = new SqlConnectionStringBuilder(SqlServerConnectionStringFactory.Build(new ConnectionRequest(profile, null, "127.0.0.1", 50000, null)));

        Assert.True(direct.IntegratedSecurity);
        Assert.Equal(string.Empty, direct.UserID);
        Assert.Equal(string.Empty, direct.ServerSPN);
        Assert.Equal("MSSQLSvc/sql.corp.example.com:1433", tunneled.ServerSPN);
    }

    [Theory]
    [InlineData(EntraAuthMode.Interactive, SqlAuthenticationMethod.ActiveDirectoryInteractive, "app", "")]
    [InlineData(EntraAuthMode.DeviceCode, SqlAuthenticationMethod.ActiveDirectoryDeviceCodeFlow, "", "")]
    [InlineData(EntraAuthMode.Default, SqlAuthenticationMethod.ActiveDirectoryDefault, "client-id", "")]
    [InlineData(EntraAuthMode.ManagedIdentity, SqlAuthenticationMethod.ActiveDirectoryManagedIdentity, "client-id", "")]
    [InlineData(EntraAuthMode.ServicePrincipal, SqlAuthenticationMethod.ActiveDirectoryServicePrincipal, "client-id", "saved-secret")]
    [InlineData(EntraAuthMode.Integrated, SqlAuthenticationMethod.ActiveDirectoryIntegrated, "", "")]
    public void SqlServerEntraUsesTheAuthenticationKeyword(EntraAuthMode mode, SqlAuthenticationMethod expected, string user, string password)
    {
        var request = Direct(DatabaseEngine.SqlServer, new ConnectionAuthSettings { Method = SignInMethod.EntraId, EntraMode = mode, EntraClientId = "client-id" });

        var builder = new SqlConnectionStringBuilder(SqlServerConnectionStringFactory.Build(request));

        Assert.Equal(expected, builder.Authentication);
        Assert.Equal(user, builder.UserID);
        Assert.Equal(password, builder.Password);
        Assert.False(builder.IntegratedSecurity);
        Assert.Equal(SqlConnectionEncryptOption.Mandatory, builder.Encrypt);
    }

    [Fact]
    public void SqlServerVerifyBehindATunnelChecksTheServersName()
    {
        var profile = new ConnectionProfile { Name = "t", Engine = DatabaseEngine.SqlServer, Host = "sql.example.com", Username = "sa", SslMode = SslMode.VerifyIdentity };

        var builder = new SqlConnectionStringBuilder(SqlServerConnectionStringFactory.Build(new ConnectionRequest(profile, "p", "127.0.0.1", 50000, null)));

        Assert.False(builder.TrustServerCertificate);
        Assert.Equal("sql.example.com", builder.HostNameInCertificate);
    }

    [Fact]
    public void PostgreSqlVerifyIdentityBehindATunnelChecksTheChainOnly()
    {
        var profile = new ConnectionProfile { Name = "t", Engine = DatabaseEngine.PostgreSql, Host = "db.example.com", SslMode = SslMode.VerifyIdentity };

        var tunneled = new NpgsqlConnectionStringBuilder(PostgreSqlConnectionStringFactory.Build(new ConnectionRequest(profile, "p", "127.0.0.1", 50000, null)));
        var direct = new NpgsqlConnectionStringBuilder(PostgreSqlConnectionStringFactory.Build(ConnectionRequest.Direct(profile, "p")));

        Assert.Equal(Npgsql.SslMode.VerifyCA, tunneled.SslMode);
        Assert.Equal(Npgsql.SslMode.VerifyFull, direct.SslMode);
    }
}
