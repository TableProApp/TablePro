using TablePro.Core.Schema;
using TablePro.Drivers.Oracle;

namespace TablePro.Drivers.Analytics.Tests;

public sealed class OracleStructureDdlTests
{
    private static readonly ObjectName Orders = new("SALES", "ORDERS");

    private static IReadOnlyList<string> Build(SchemaChange change) => OracleDdl.Build(Orders, change);

    [Fact]
    public void AddsDropsAndRenamesChecks()
    {
        Assert.Equal(["ALTER TABLE \"SALES\".\"ORDERS\" ADD CONSTRAINT \"CK_TOTAL\" CHECK (TOTAL >= 0)"], Build(new AddCheckConstraint(new("CK_TOTAL", "TOTAL >= 0"))));
        Assert.Equal(["ALTER TABLE \"SALES\".\"ORDERS\" DROP CONSTRAINT \"CK_TOTAL\""], Build(new DropCheckConstraint("CK_TOTAL")));
        Assert.Equal(
            ["ALTER TABLE \"SALES\".\"ORDERS\" RENAME CONSTRAINT \"CK_OLD\" TO \"CK_NEW\""],
            Build(new AlterCheckConstraint(new("CK_OLD", "TOTAL >= 0"), new("CK_NEW", "TOTAL >= 0"))));
    }

    [Fact]
    public void ReplacesACheckInTwoStatements()
    {
        Assert.Equal(
        [
            "ALTER TABLE \"SALES\".\"ORDERS\" DROP CONSTRAINT \"CK_TOTAL\"",
            "ALTER TABLE \"SALES\".\"ORDERS\" ADD CONSTRAINT \"CK_TOTAL\" CHECK (TOTAL > 0)",
        ], Build(new AlterCheckConstraint(new("CK_TOTAL", "TOTAL >= 0"), new("CK_TOTAL", "TOTAL > 0"))));
    }

    [Fact]
    public void AddsARangePartitionAndAHashOne()
    {
        Assert.Equal(["ALTER TABLE \"SALES\".\"ORDERS\" ADD PARTITION \"P2026\" VALUES LESS THAN (2027)"], Build(new AddPartition(new("P2026", "VALUES LESS THAN (2027)"))));
        Assert.Equal(["ALTER TABLE \"SALES\".\"ORDERS\" ADD PARTITION \"P5\""], Build(new AddPartition(new("P5", " "))));
    }

    [Fact]
    public void DropsAndTruncatesKeepingGlobalIndexesUsable()
    {
        Assert.Equal(["ALTER TABLE \"SALES\".\"ORDERS\" DROP PARTITION \"P2024\" UPDATE GLOBAL INDEXES"], Build(new DropPartition(new PartitionInfo("P2024"))));
        Assert.Equal(
            ["ALTER TABLE \"SALES\".\"ORDERS\" TRUNCATE SUBPARTITION \"P2024_SP1\" UPDATE GLOBAL INDEXES"],
            Build(new TruncatePartition(new PartitionInfo("P2024_SP1") { Parent = "P2024" })));
    }

    [Fact]
    public void SetsTableOptions()
    {
        var sql = Build(new SetTableOptions(
        [
            new(TableOptionNames.Comment, null, "Customer orders"),
            new(TableOptionNames.Tablespace, "USERS", "fast_data"),
            new(TableOptionNames.PctFree, "10", "20"),
            new(TableOptionNames.Logging, "YES", "no"),
            new(TableOptionNames.RowMovement, "DISABLED", "ENABLED"),
        ]));

        Assert.Equal(
        [
            "COMMENT ON TABLE \"SALES\".\"ORDERS\" IS 'Customer orders'",
            "ALTER TABLE \"SALES\".\"ORDERS\" MOVE TABLESPACE FAST_DATA UPDATE INDEXES",
            "ALTER TABLE \"SALES\".\"ORDERS\" PCTFREE 20",
            "ALTER TABLE \"SALES\".\"ORDERS\" NOLOGGING",
            "ALTER TABLE \"SALES\".\"ORDERS\" ENABLE ROW MOVEMENT",
        ], sql);
    }

    [Fact]
    public void ClearingTheCommentSetsItEmpty()
    {
        Assert.Equal(["COMMENT ON TABLE \"SALES\".\"ORDERS\" IS ''"], Build(new SetTableOptions([new(TableOptionNames.Comment, "old", null)])));
    }

    [Theory]
    [InlineData(TableOptionNames.PctFree, "100")]
    [InlineData(TableOptionNames.Logging, "MAYBE")]
    public void RefusesValuesTheGrammarCannotTake(string option, string value)
    {
        Assert.Throws<ArgumentException>(() => Build(new SetTableOptions([new(option, null, value)])));
    }

    [Theory]
    [InlineData("\"QTY\" IS NOT NULL", true)]
    [InlineData("\"QTY\" is not null", true)]
    [InlineData("QTY > 0", false)]
    [InlineData("\"A\" IS NOT NULL OR \"B\" IS NOT NULL", false)]
    public void TellsAColumnsNotNullFromARealCheck(string condition, bool isNotNull)
    {
        Assert.Equal(isNotNull, OracleDdl.IsNotNullCheck(condition));
    }

    [Theory]
    [InlineData("RANGE", "2025", "VALUES LESS THAN (2025)")]
    [InlineData("LIST", "'DE', 'FR'", "VALUES ('DE', 'FR')")]
    [InlineData("HASH", null, null)]
    public void SpellsPartitionBoundsByMethod(string method, string? highValue, string? expected)
    {
        Assert.Equal(expected, OracleDdl.PartitionBound(method, highValue));
    }
}
