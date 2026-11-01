using TablePro.Core.Schema;
using TablePro.Drivers.SqlServer;

namespace TablePro.Drivers.Tests;

public sealed class SqlServerStructureDdlTests
{
    private static readonly ObjectName Orders = new("sales", "orders");

    [Fact]
    public void AddsAndDropsACheck()
    {
        Assert.Equal(
            ["ALTER TABLE [sales].[orders] ADD CONSTRAINT [CK_total] CHECK (total >= 0)"],
            SqlServerDdl.Build(Orders, new AddCheckConstraint(new("CK_total", "total >= 0"))));
        Assert.Equal(["ALTER TABLE [sales].[orders] DROP CONSTRAINT [CK_total]"], SqlServerDdl.Build(Orders, new DropCheckConstraint("CK_total")));
    }

    [Fact]
    public void RenamesACheckWithSpRename()
    {
        var sql = SqlServerDdl.Build(Orders, new AlterCheckConstraint(new("CK_old", "total >= 0"), new("CK_new", "total >= 0")));

        Assert.Equal(["EXEC sys.sp_rename N'[sales].[CK_old]', N'CK_new', N'OBJECT'"], sql);
    }

    [Fact]
    public void ReplacesACheckInTwoStatements()
    {
        var sql = SqlServerDdl.Build(Orders, new AlterCheckConstraint(new("CK_total", "total >= 0"), new("CK_total", "total > 0")));

        Assert.Equal(
        [
            "ALTER TABLE [sales].[orders] DROP CONSTRAINT [CK_total]",
            "ALTER TABLE [sales].[orders] ADD CONSTRAINT [CK_total] CHECK (total > 0)",
        ], sql);
    }

    [Fact]
    public void HasNoPartitionStatements()
    {
        Assert.Empty(SqlServerDdl.Build(Orders, new DropPartition(new PartitionInfo("1"))));
        Assert.Empty(SqlServerDdl.Build(Orders, new AddPartition(new("p", "x"))));
    }

    [Fact]
    public void SetsCompressionAndLockEscalation()
    {
        var sql = SqlServerDdl.Build(Orders, new SetTableOptions(
        [
            new(TableOptionNames.DataCompression, "NONE", "page"),
            new(TableOptionNames.LockEscalation, "TABLE", "AUTO"),
        ]));

        Assert.Equal(
        [
            "ALTER TABLE [sales].[orders] REBUILD WITH (DATA_COMPRESSION = PAGE)",
            "ALTER TABLE [sales].[orders] SET (LOCK_ESCALATION = AUTO)",
        ], sql);
    }

    [Fact]
    public void WritesTheTableDescriptionAsAnExtendedProperty()
    {
        var sql = Assert.Single(SqlServerDdl.Build(Orders, new SetTableOptions([new(TableOptionNames.Comment, null, "Orders")])));

        Assert.Contains("fn_listextendedproperty(N'MS_Description', N'SCHEMA', N'sales', N'TABLE', N'orders', NULL, NULL)", sql, StringComparison.Ordinal);
        Assert.Contains("sp_updateextendedproperty @name = N'MS_Description', @value = N'Orders', @level0type = N'SCHEMA', @level0name = N'sales', @level1type = N'TABLE', @level1name = N'orders'", sql, StringComparison.Ordinal);
        Assert.Contains("sp_addextendedproperty", sql, StringComparison.Ordinal);
        Assert.DoesNotContain("COLUMN", sql, StringComparison.Ordinal);
    }

    [Fact]
    public void ClearingTheDescriptionDropsTheProperty()
    {
        var sql = Assert.Single(SqlServerDdl.Build(Orders, new SetTableOptions([new(TableOptionNames.Comment, "Orders", null)])));

        Assert.Contains("sp_dropextendedproperty @name = N'MS_Description', @level0type", sql, StringComparison.Ordinal);
        Assert.DoesNotContain("sp_addextendedproperty", sql, StringComparison.Ordinal);
    }

    [Fact]
    public void RefusesAnUnknownCompression()
    {
        Assert.Throws<ArgumentException>(() => SqlServerDdl.Build(Orders, new SetTableOptions([new(TableOptionNames.DataCompression, null, "COLUMNSTORE")])));
    }
}
