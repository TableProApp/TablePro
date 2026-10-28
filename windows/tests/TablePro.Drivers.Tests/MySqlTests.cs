using MySqlConnector;
using TablePro.Core.Connections;
using TablePro.Core.Schema;
using TablePro.Drivers.MySql;

namespace TablePro.Drivers.Tests;

public sealed class MySqlTests
{
    private static readonly ObjectName Orders = new(null, "orders");

    [Fact]
    public void ConnectionStringCarriesEndpointAndCompatibilityOptions()
    {
        var builder = new MySqlConnectionStringBuilder(MySqlConnectionStringFactory.Build(Profiles.Request(DatabaseEngine.MySql)));

        Assert.Equal("127.0.0.1", builder.Server);
        Assert.Equal(15432u, builder.Port);
        Assert.Equal("shop", builder.Database);
        Assert.Equal("app", builder.UserID);
        Assert.Equal("s3cret;'x", builder.Password);
        Assert.Equal(7u, builder.ConnectionTimeout);
        Assert.True(builder.Pooling);
        Assert.True(builder.AllowUserVariables);
        Assert.True(builder.AllowZeroDateTime);
        Assert.True(builder.ConvertZeroDateTime);
    }

    [Fact]
    public void ConnectionStringLeavesTheDatabaseOutWhenNoneIsChosen()
    {
        var builder = new MySqlConnectionStringBuilder(MySqlConnectionStringFactory.Build(Profiles.Request(DatabaseEngine.MariaDb, user: null, database: null)));

        Assert.Equal(string.Empty, builder.Database);
        Assert.Equal("root", builder.UserID);
    }

    [Theory]
    [InlineData(SslMode.Disabled, MySqlSslMode.None)]
    [InlineData(SslMode.Preferred, MySqlSslMode.Preferred)]
    [InlineData(SslMode.Required, MySqlSslMode.Required)]
    [InlineData(SslMode.VerifyCa, MySqlSslMode.VerifyCA)]
    [InlineData(SslMode.VerifyIdentity, MySqlSslMode.VerifyFull)]
    public void MapsEverySslMode(SslMode mode, MySqlSslMode expected)
    {
        // Direct, since behind a tunnel Verify identity checks the chain only.
        var request = TablePro.Core.Drivers.ConnectionRequest.Direct(Profiles.Request(DatabaseEngine.MySql, ssl: mode).Profile, null);
        var builder = new MySqlConnectionStringBuilder(MySqlConnectionStringFactory.Build(request));

        Assert.Equal(expected, builder.SslMode);
    }

    [Fact]
    public void AdditionalOptionsOverrideDefaults()
    {
        var request = Profiles.Request(DatabaseEngine.MySql, options: new Dictionary<string, string> { ["Maximum Pool Size"] = "3" });

        Assert.Equal(3u, new MySqlConnectionStringBuilder(MySqlConnectionStringFactory.Build(request)).MaximumPoolSize);
    }

    [Fact]
    public void InitializationBatchesReadOnlyAndStartupCommands()
    {
        Assert.Null(MySqlSession.BuildInitializeSql(readOnly: false, []));
        Assert.Equal("SET SESSION TRANSACTION READ ONLY", MySqlSession.BuildInitializeSql(readOnly: true, []));
        Assert.Equal(
            "SET SESSION TRANSACTION READ ONLY;\nSET NAMES utf8mb4;\nSET time_zone = '+00:00'",
            MySqlSession.BuildInitializeSql(readOnly: true, ["SET NAMES utf8mb4", "SET time_zone = '+00:00'"]));
    }

    [Fact]
    public void CreatesATableWithAutoIncrementAndComments()
    {
        var ddl = MySqlDdl.Build(Orders, new CreateTable(new ObjectName("shop", "orders"), [
            new ColumnDefinition("id", "BIGINT UNSIGNED", IsNullable: false, IsPrimaryKey: true, IsIdentity: true),
            new ColumnDefinition("note", "VARCHAR(100)", DefaultExpression: "'x'", Comment: "It's a \\ note"),
        ]));

        Assert.Equal(
            "CREATE TABLE `shop`.`orders` (\n  `id` BIGINT UNSIGNED NOT NULL AUTO_INCREMENT PRIMARY KEY,\n"
            + "  `note` VARCHAR(100) NULL DEFAULT 'x' COMMENT 'It''s a \\\\ note'\n)",
            Assert.Single(ddl));
    }

    [Fact]
    public void AlterColumnRestatesTheColumnAndRenamesWithChange()
    {
        var before = new ColumnDefinition("qty", "INT");
        var modify = MySqlDdl.Build(Orders, new AlterColumn(before, before with { DataType = "BIGINT", IsNullable = false }));
        var change = MySqlDdl.Build(Orders, new AlterColumn(before, before with { Name = "quantity" }));

        Assert.Equal(["ALTER TABLE `orders` MODIFY COLUMN `qty` BIGINT NOT NULL"], modify);
        Assert.Equal(["ALTER TABLE `orders` CHANGE COLUMN `qty` `quantity` INT NULL"], change);
    }

    [Fact]
    public void WritesIndexKeyAndObjectStatements()
    {
        Assert.Equal(["CREATE INDEX `ix` ON `orders` (`a`)"], MySqlDdl.Build(Orders, new CreateIndex(new IndexDefinition("ix", ["a"]))));
        Assert.Equal(["DROP INDEX `ix` ON `orders`"], MySqlDdl.Build(Orders, new DropIndex("ix")));
        Assert.Equal(["ALTER TABLE `orders` DROP PRIMARY KEY"], MySqlDdl.Build(Orders, new DropIndex("PRIMARY")));
        Assert.Equal(["ALTER TABLE `orders` DROP FOREIGN KEY `fk`"], MySqlDdl.Build(Orders, new DropForeignKey("fk")));
        Assert.Equal(
            ["ALTER TABLE `orders` ADD CONSTRAINT `fk` FOREIGN KEY (`customer_id`) REFERENCES `customers` (`id`) ON DELETE SET NULL ON UPDATE CASCADE"],
            MySqlDdl.Build(Orders, new AddForeignKey(new ForeignKeyDefinition("fk", ["customer_id"], new ObjectName(null, "customers"), ["id"], "set null", "cascade"))));
        Assert.Equal(["RENAME TABLE `orders` TO `orders_old`"], MySqlDdl.Build(Orders, new RenameTable("orders_old")));
        Assert.Equal(["RENAME TABLE `shop`.`orders` TO `shop`.`archive`"], MySqlDdl.Build(new ObjectName("shop", "orders"), new RenameTable("archive")));
        Assert.Equal(["ALTER TABLE `orders` RENAME COLUMN `a` TO `b`"], MySqlDdl.Build(Orders, new RenameColumn("a", "b")));
        Assert.Equal(["TRUNCATE TABLE `orders`"], MySqlDdl.Build(Orders, new TruncateTable()));
        Assert.Equal(["DROP PROCEDURE `refresh`"], MySqlDdl.Build(Orders, new DropObject(new DatabaseObject(new ObjectName(null, "refresh"), ObjectKind.Procedure))));
        Assert.Equal("CREATE DATABASE `a``b`", MySqlDdl.CreateDatabase("a`b"));
    }

    [Fact]
    public void ReadsDefinitionsFromTheRightShowCreateColumn()
    {
        Assert.Equal(("SHOW CREATE TABLE `orders`", 1), MySqlDdl.ShowCreate(new DatabaseObject(Orders, ObjectKind.Table)));
        Assert.Equal(("SHOW CREATE PROCEDURE `shop`.`p`", 2), MySqlDdl.ShowCreate(new DatabaseObject(new ObjectName("shop", "p"), ObjectKind.Procedure)));
        Assert.Null(MySqlDdl.ShowCreate(new DatabaseObject(Orders, ObjectKind.MaterializedView)));
    }

    [Fact]
    public void KillAcceptsOnlyAConnectionNumber()
    {
        Assert.Equal("KILL CONNECTION 42", MySqlDdl.Kill(42L));
        Assert.Equal("KILL CONNECTION 7", MySqlDdl.Kill("7"));
        Assert.Throws<FormatException>(() => MySqlDdl.Kill("7; DROP TABLE x"));
    }
}
