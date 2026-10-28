using Microsoft.Data.SqlClient;
using TablePro.Core.Connections;
using TablePro.Core.Schema;
using TablePro.Drivers.SqlServer;

namespace TablePro.Drivers.Tests;

public sealed class SqlServerTests
{
    private static readonly ObjectName Orders = new("sales", "orders");

    [Fact]
    public void ConnectionStringUsesTcpEndpointAndSqlLogin()
    {
        var builder = new SqlConnectionStringBuilder(SqlServerConnectionStringFactory.Build(Profiles.Request(DatabaseEngine.SqlServer)));

        Assert.Equal("tcp:127.0.0.1,15432", builder.DataSource);
        Assert.Equal("shop", builder.InitialCatalog);
        Assert.Equal("app", builder.UserID);
        Assert.Equal("s3cret;'x", builder.Password);
        Assert.False(builder.IntegratedSecurity);
        Assert.Equal(7, builder.ConnectTimeout);
        Assert.True(builder.Pooling);
        Assert.Equal(ApplicationIntent.ReadWrite, builder.ApplicationIntent);
    }

    [Fact]
    public void NoUserNameMeansWindowsAuthentication()
    {
        var builder = new SqlConnectionStringBuilder(SqlServerConnectionStringFactory.Build(Profiles.Request(DatabaseEngine.SqlServer, user: null)));

        Assert.True(builder.IntegratedSecurity);
        Assert.Equal(string.Empty, builder.UserID);
    }

    [Theory]
    [InlineData(SslMode.Disabled, false, true)]
    [InlineData(SslMode.Preferred, false, true)]
    [InlineData(SslMode.Required, true, true)]
    [InlineData(SslMode.VerifyCa, true, false)]
    [InlineData(SslMode.VerifyIdentity, true, false)]
    public void MapsEverySslMode(SslMode mode, bool mandatory, bool trust)
    {
        var builder = new SqlConnectionStringBuilder(SqlServerConnectionStringFactory.Build(Profiles.Request(DatabaseEngine.SqlServer, ssl: mode)));

        Assert.Equal(mandatory ? SqlConnectionEncryptOption.Mandatory : SqlConnectionEncryptOption.Optional, builder.Encrypt);
        Assert.Equal(trust, builder.TrustServerCertificate);
    }

    [Fact]
    public void ReadOnlyProfileDeclaresReadOnlyIntent()
    {
        var builder = new SqlConnectionStringBuilder(
            SqlServerConnectionStringFactory.Build(Profiles.Request(DatabaseEngine.SqlServer, safeMode: SafeModeLevel.ReadOnly)));

        Assert.Equal(ApplicationIntent.ReadOnly, builder.ApplicationIntent);
    }

    [Fact]
    public void AdditionalOptionsOverrideDefaults()
    {
        var request = Profiles.Request(DatabaseEngine.SqlServer, options: new Dictionary<string, string> { ["Multi Subnet Failover"] = "true" });

        Assert.True(new SqlConnectionStringBuilder(SqlServerConnectionStringFactory.Build(request)).MultiSubnetFailover);
    }

    [Fact]
    public void CreatesATableWithIdentityNamedDefaultAndDescription()
    {
        var ddl = SqlServerDdl.Build(Orders, new CreateTable(Orders, [
            new ColumnDefinition("id", "int", IsNullable: false, IsPrimaryKey: true, IsIdentity: true),
            new ColumnDefinition("status", "nvarchar(20)", IsNullable: false, DefaultExpression: "N'new'", Comment: "Order state"),
        ]));

        Assert.Equal(
            "CREATE TABLE [sales].[orders] (\n  [id] int IDENTITY(1,1) NOT NULL PRIMARY KEY,\n"
            + "  [status] nvarchar(20) NOT NULL CONSTRAINT [DF_orders_status] DEFAULT N'new'\n)",
            ddl[0]);
        Assert.Contains("EXEC sys.sp_addextendedproperty @name = N'MS_Description', @value = N'Order state'", ddl[1], StringComparison.Ordinal);
        Assert.Contains("@level2type = N'COLUMN', @level2name = N'status'", ddl[1], StringComparison.Ordinal);
    }

    [Fact]
    public void DropColumnRemovesItsDefaultConstraintFirst()
    {
        var ddl = SqlServerDdl.Build(Orders, new DropColumn("status"));

        Assert.Equal(2, ddl.Count);
        Assert.Contains("WHERE dc.parent_object_id = OBJECT_ID(N'[sales].[orders]') AND c.name = N'status';", ddl[0], StringComparison.Ordinal);
        Assert.Contains("EXEC (N'ALTER TABLE ' + N'[sales].[orders]' + N' DROP CONSTRAINT ' + QUOTENAME(@constraint))", ddl[0], StringComparison.Ordinal);
        Assert.Equal("ALTER TABLE [sales].[orders] DROP COLUMN [status]", ddl[1]);
    }

    [Fact]
    public void AltersTypeDefaultCommentAndName()
    {
        var before = new ColumnDefinition("qty", "int", DefaultExpression: "((0))", Comment: "old");
        var after = new ColumnDefinition("quantity", "bigint", IsNullable: false, DefaultExpression: "1", Comment: null);

        var ddl = SqlServerDdl.Build(Orders, new AlterColumn(before, after));

        Assert.Equal("ALTER TABLE [sales].[orders] ALTER COLUMN [qty] bigint NOT NULL", ddl[0]);
        Assert.StartsWith("DECLARE @constraint sysname;", ddl[1], StringComparison.Ordinal);
        Assert.Equal("ALTER TABLE [sales].[orders] ADD CONSTRAINT [DF_orders_qty] DEFAULT 1 FOR [qty]", ddl[2]);
        Assert.Contains("EXEC sys.sp_dropextendedproperty", ddl[3], StringComparison.Ordinal);
        Assert.Equal("EXEC sys.sp_rename N'[sales].[orders].[qty]', N'quantity', N'COLUMN'", ddl[4]);
    }

    [Fact]
    public void WritesIndexKeyAndObjectStatements()
    {
        Assert.Equal(["CREATE UNIQUE INDEX [ux] ON [sales].[orders] ([a], [b])"], SqlServerDdl.Build(Orders, new CreateIndex(new IndexDefinition("ux", ["a", "b"], true))));
        var drop = Assert.Single(SqlServerDdl.Build(Orders, new DropIndex("ux")));
        Assert.Contains("ALTER TABLE [sales].[orders] DROP CONSTRAINT [ux]", drop, StringComparison.Ordinal);
        Assert.Contains("DROP INDEX [ux] ON [sales].[orders]", drop, StringComparison.Ordinal);
        Assert.Equal(
            ["ALTER TABLE [sales].[orders] ADD CONSTRAINT [fk] FOREIGN KEY ([customer_id]) REFERENCES [sales].[customers] ([id]) ON DELETE CASCADE"],
            SqlServerDdl.Build(Orders, new AddForeignKey(new ForeignKeyDefinition("fk", ["customer_id"], new ObjectName(null, "customers"), ["id"], "CASCADE"))));
        Assert.Equal(["ALTER TABLE [sales].[orders] DROP CONSTRAINT [fk]"], SqlServerDdl.Build(Orders, new DropForeignKey("fk")));
        Assert.Equal(["EXEC sys.sp_rename N'[sales].[orders]', N'orders_old'"], SqlServerDdl.Build(Orders, new RenameTable("orders_old")));
        Assert.Equal(["TRUNCATE TABLE [sales].[orders]"], SqlServerDdl.Build(Orders, new TruncateTable()));
        Assert.Equal(["DROP SEQUENCE [sales].[seq]"], SqlServerDdl.Build(Orders, new DropObject(new DatabaseObject(new ObjectName("sales", "seq"), ObjectKind.Sequence))));
    }

    [Fact]
    public void EscapesBracketsAndQuotes()
    {
        var ddl = SqlServerDdl.Build(new ObjectName("s", "a]b"), new RenameColumn("it's", "c"));

        Assert.Equal(["EXEC sys.sp_rename N'[s].[a]]b].[it''s]', N'c', N'COLUMN'"], ddl);
        Assert.Equal("CREATE DATABASE [x]]y]", SqlServerDdl.CreateDatabase("x]y"));
    }

    [Fact]
    public void KillAcceptsOnlyASessionNumber()
    {
        Assert.Equal("KILL 53", SqlServerDdl.Kill((short)53));
        Assert.Throws<FormatException>(() => SqlServerDdl.Kill("53 --"));
    }

    [Fact]
    public void SpellsReferentialActionsWithSpaces() => Assert.Equal("SET NULL", SqlServerDdl.ReferentialAction("SET_NULL"));
}
