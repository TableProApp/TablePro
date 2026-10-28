using TablePro.Core.Schema;
using TablePro.Drivers.ClickHouse;

namespace TablePro.Drivers.Analytics.Tests;

public sealed class ClickHouseStructureDdlTests
{
    private static readonly ObjectName Events = new("db", "events");

    private static IReadOnlyList<string> Build(SchemaChange change) => ClickHouseDdl.Build(Events, change);

    [Fact]
    public void AddsAndDropsACheck()
    {
        Assert.Equal(["ALTER TABLE `db`.`events` ADD CONSTRAINT `c_score` CHECK score >= 0"], Build(new AddCheckConstraint(new("c_score", "score >= 0"))));
        Assert.Equal(["ALTER TABLE `db`.`events` DROP CONSTRAINT `c_score`"], Build(new DropCheckConstraint("c_score")));
    }

    [Fact]
    public void ReplacesACheckByDroppingAndAddingIt()
    {
        Assert.Equal(
        [
            "ALTER TABLE `db`.`events` DROP CONSTRAINT `c_old`",
            "ALTER TABLE `db`.`events` ADD CONSTRAINT `c_new` CHECK score > 0",
        ], Build(new AlterCheckConstraint(new("c_old", "score >= 0"), new("c_new", "score > 0"))));
    }

    [Fact]
    public void DropsAPartitionByItsIdAndCannotAddOne()
    {
        Assert.Equal(["ALTER TABLE `db`.`events` DROP PARTITION ID '202401'"], Build(new DropPartition(new PartitionInfo("202401", "202401"))));
        Assert.Empty(Build(new AddPartition(new("202402", string.Empty))));
        Assert.Empty(Build(new TruncatePartition(new PartitionInfo("202401"))));
    }

    [Fact]
    public void ChangesTheComment()
    {
        Assert.Equal(["ALTER TABLE `db`.`events` MODIFY COMMENT 'Raw events'"], Build(new SetTableOptions([new(TableOptionNames.Comment, null, "Raw events")])));
        Assert.Equal(["ALTER TABLE `db`.`events` MODIFY COMMENT ''"], Build(new SetTableOptions([new(TableOptionNames.Comment, "Raw events", null)])));
    }

    [Fact]
    public void ReadsChecksFromTheCreateQueryAndSkipsAssumptions()
    {
        const string Create = """
            CREATE TABLE db.events (`id` UInt64, `score` Float64, CONSTRAINT c_score CHECK score >= 0, CONSTRAINT `c id` CHECK id > 0, CONSTRAINT a_id ASSUME id < 1000) ENGINE = MergeTree ORDER BY id SETTINGS index_granularity = 8192
            """;

        var checks = ClickHouseDdl.CheckConstraints(Create);

        Assert.Equal(["c_score", "c id"], checks.Select(c => c.Name));
        Assert.Equal("score >= 0", checks[0].Expression);
    }

    [Fact]
    public void ReadsBlankOptionsAsMissing()
    {
        var options = ClickHouseDdl.ReadOptions("MergeTree", "id", "id", string.Empty, string.Empty);

        Assert.Contains(new TableOption(TableOptionNames.Engine, "MergeTree"), options);
        Assert.Contains(new TableOption(TableOptionNames.SamplingKey, null), options);
        Assert.Contains(new TableOption(TableOptionNames.Comment, null), options);
    }
}
