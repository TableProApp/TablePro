using TablePro.Core.Schema;
using TablePro.Drivers.PostgreSql;

namespace TablePro.Drivers.Tests;

public sealed class PostgreSqlStructureDdlTests
{
    private static readonly ObjectName Orders = new("sales", "orders");

    [Fact]
    public void AddsANamedCheck()
    {
        var sql = PostgreSqlDdl.Build(Orders, new AddCheckConstraint(new("ck_total", " total >= 0 ")));

        Assert.Equal(["ALTER TABLE \"sales\".\"orders\" ADD CONSTRAINT \"ck_total\" CHECK (total >= 0)"], sql);
    }

    [Fact]
    public void RefusesACheckWithoutAnExpression()
    {
        Assert.Empty(PostgreSqlDdl.Build(Orders, new AddCheckConstraint(new("ck_total", " "))));
    }

    [Fact]
    public void DropsACheck()
    {
        Assert.Equal(["ALTER TABLE \"sales\".\"orders\" DROP CONSTRAINT \"ck_total\""], PostgreSqlDdl.Build(Orders, new DropCheckConstraint("ck_total")));
    }

    [Fact]
    public void RenamesACheckWithoutRecheckingRows()
    {
        var sql = PostgreSqlDdl.Build(Orders, new AlterCheckConstraint(new("ck_old", "total >= 0"), new("ck_new", "total >= 0")));

        Assert.Equal(["ALTER TABLE \"sales\".\"orders\" RENAME CONSTRAINT \"ck_old\" TO \"ck_new\""], sql);
    }

    [Fact]
    public void ReplacesACheckInOneAtomicStatement()
    {
        var sql = PostgreSqlDdl.Build(Orders, new AlterCheckConstraint(new("ck_total", "total >= 0"), new("ck_total", "total > 0")));

        Assert.Equal(["ALTER TABLE \"sales\".\"orders\" DROP CONSTRAINT \"ck_total\", ADD CONSTRAINT \"ck_total\" CHECK (total > 0)"], sql);
    }

    [Theory]
    [InlineData("FOR VALUES FROM ('2026-01-01') TO ('2027-01-01')", "FOR VALUES FROM ('2026-01-01') TO ('2027-01-01')")]
    [InlineData("FROM ('2026-01-01') TO ('2027-01-01')", "FOR VALUES FROM ('2026-01-01') TO ('2027-01-01')")]
    [InlineData("IN ('de', 'fr')", "FOR VALUES IN ('de', 'fr')")]
    [InlineData("DEFAULT", "DEFAULT")]
    public void CreatesAPartitionOfTheTable(string bound, string expected)
    {
        var sql = PostgreSqlDdl.Build(Orders, new AddPartition(new("orders_2026", bound)));

        Assert.Equal(["CREATE TABLE \"sales\".\"orders_2026\" PARTITION OF \"sales\".\"orders\" " + expected], sql);
    }

    [Fact]
    public void DropsAndTruncatesAPartitionInItsOwnSchema()
    {
        var partition = new PartitionInfo("orders_2023") { Schema = "archive", IsRelation = true };

        Assert.Equal(["DROP TABLE \"archive\".\"orders_2023\""], PostgreSqlDdl.Build(Orders, new DropPartition(partition)));
        Assert.Equal(["TRUNCATE TABLE \"archive\".\"orders_2023\""], PostgreSqlDdl.Build(Orders, new TruncatePartition(partition)));
    }

    [Fact]
    public void APartitionWithoutASchemaIsBesideItsParent()
    {
        var partition = new PartitionInfo("orders_2024") { IsRelation = true };

        Assert.Equal(["DROP TABLE \"sales\".\"orders_2024\""], PostgreSqlDdl.Build(Orders, new DropPartition(partition)));
    }

    [Fact]
    public void SetsStorageParametersInOneStatementAndTheRestApart()
    {
        var sql = PostgreSqlDdl.Build(Orders, new SetTableOptions(
        [
            new(TableOptionNames.FillFactor, null, "70"),
            new(TableOptionNames.StorageParameters, "autovacuum_enabled=false, toast_tuple_target=4096", "autovacuum_enabled=true, parallel_workers=4"),
            new(TableOptionNames.Tablespace, null, "fast_ssd"),
            new(TableOptionNames.Persistence, "LOGGED", "unlogged"),
            new(TableOptionNames.Comment, null, "Customer's orders"),
        ]));

        Assert.Equal(
        [
            "ALTER TABLE \"sales\".\"orders\" SET (fillfactor=70, autovacuum_enabled=true, parallel_workers=4)",
            "ALTER TABLE \"sales\".\"orders\" RESET (toast_tuple_target)",
            "ALTER TABLE \"sales\".\"orders\" SET TABLESPACE \"fast_ssd\"",
            "ALTER TABLE \"sales\".\"orders\" SET UNLOGGED",
            "COMMENT ON TABLE \"sales\".\"orders\" IS 'Customer''s orders'",
        ], sql);
    }

    [Fact]
    public void ClearingOptionsResetsThem()
    {
        var sql = PostgreSqlDdl.Build(Orders, new SetTableOptions(
        [
            new(TableOptionNames.FillFactor, "70", null),
            new(TableOptionNames.Tablespace, "fast_ssd", null),
            new(TableOptionNames.Comment, "old", null),
        ]));

        Assert.Equal(
        [
            "ALTER TABLE \"sales\".\"orders\" RESET (fillfactor)",
            "ALTER TABLE \"sales\".\"orders\" SET TABLESPACE \"pg_default\"",
            "COMMENT ON TABLE \"sales\".\"orders\" IS NULL",
        ], sql);
    }

    [Fact]
    public void QuotesAParameterValueThatIsNotAPlainWord()
    {
        var sql = PostgreSqlDdl.Build(Orders, new SetTableOptions([new(TableOptionNames.StorageParameters, null, "toast.autovacuum_enabled=off, x=a b")]));

        Assert.Equal(["ALTER TABLE \"sales\".\"orders\" SET (toast.autovacuum_enabled=off, x='a b')"], sql);
    }

    [Theory]
    [InlineData(TableOptionNames.FillFactor, "5")]
    [InlineData(TableOptionNames.FillFactor, "abc")]
    [InlineData(TableOptionNames.Persistence, "TEMPORARY")]
    [InlineData(TableOptionNames.StorageParameters, "fillfactor")]
    [InlineData(TableOptionNames.StorageParameters, "x); DROP TABLE t; --=1")]
    public void RefusesValuesTheGrammarCannotTake(string option, string value)
    {
        Assert.Throws<ArgumentException>(() => PostgreSqlDdl.Build(Orders, new SetTableOptions([new(option, null, value)])));
    }

    [Fact]
    public void ReadsFillFactorApartFromTheOtherParameters()
    {
        var options = PostgreSqlDdl.ReadOptions("fast_ssd", ["fillfactor=70", "autovacuum_enabled=false"], "u", "Orders");

        Assert.Contains(new TableOption(TableOptionNames.FillFactor, "70"), options);
        Assert.Contains(new TableOption(TableOptionNames.StorageParameters, "autovacuum_enabled=false"), options);
        Assert.Contains(new TableOption(TableOptionNames.Persistence, "UNLOGGED"), options);
        Assert.Contains(new TableOption(TableOptionNames.Tablespace, "fast_ssd"), options);
    }

    [Theory]
    [InlineData("RANGE (created_at)", "RANGE", "created_at")]
    [InlineData("LIST (lower(country))", "LIST", "lower(country)")]
    [InlineData("HASH (id, region)", "HASH", "id, region")]
    public void SplitsThePartitionKey(string definition, string method, string key)
    {
        Assert.Equal((method, key), PostgreSqlDdl.SplitPartitionKey(definition));
    }
}
