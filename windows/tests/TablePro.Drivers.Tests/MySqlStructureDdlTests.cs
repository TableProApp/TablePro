using TablePro.Core.Schema;
using TablePro.Drivers.MySql;

namespace TablePro.Drivers.Tests;

public sealed class MySqlStructureDdlTests
{
    private static readonly ObjectName Orders = new("shop", "orders");

    [Fact]
    public void AddsACheck()
    {
        Assert.Equal(
            ["ALTER TABLE `shop`.`orders` ADD CONSTRAINT `ck_total` CHECK (total >= 0)"],
            MySqlDdl.Build(Orders, new AddCheckConstraint(new("ck_total", "total >= 0"))));
    }

    [Theory]
    [InlineData("8.0.18", false, "DROP CHECK")]
    [InlineData("8.0.19", false, "DROP CONSTRAINT")]
    [InlineData("8.4.3", false, "DROP CONSTRAINT")]
    [InlineData("10.11.6-MariaDB", true, "DROP CONSTRAINT")]
    public void DropsACheckWithTheKeywordTheServerTakes(string version, bool mariaDb, string keyword)
    {
        var server = MySqlServer.Parse(version, mariaDb);

        Assert.Equal([$"ALTER TABLE `shop`.`orders` {keyword} `ck_total`"], MySqlDdl.Build(Orders, new DropCheckConstraint("ck_total"), server));
    }

    [Fact]
    public void ReplacesACheckByDroppingAndAddingIt()
    {
        var sql = MySqlDdl.Build(Orders, new AlterCheckConstraint(new("ck_old", "total >= 0"), new("ck_new", "total >= 0")));

        Assert.Equal(
        [
            "ALTER TABLE `shop`.`orders` DROP CONSTRAINT `ck_old`",
            "ALTER TABLE `shop`.`orders` ADD CONSTRAINT `ck_new` CHECK (total >= 0)",
        ], sql);
    }

    [Theory]
    [InlineData("5.7.44", false, false)]
    [InlineData("8.0.15", false, false)]
    [InlineData("8.0.16", false, true)]
    [InlineData("10.2.21-MariaDB", true, false)]
    [InlineData("10.2.22-MariaDB", true, true)]
    [InlineData("10.3.9-MariaDB", true, false)]
    [InlineData("10.3.10-MariaDB", true, true)]
    [InlineData("5.5.5-10.4.32-MariaDB", false, true)]
    [InlineData("11.4.2-MariaDB", true, true)]
    [InlineData("", false, false)]
    public void KnowsWhichServersKeepChecks(string version, bool mariaDb, bool keeps)
    {
        Assert.Equal(keeps, MySqlServer.Parse(version, mariaDb).HasCheckConstraints);
    }

    [Fact]
    public void AddsARangePartition()
    {
        Assert.Equal(
            ["ALTER TABLE `shop`.`orders` ADD PARTITION (PARTITION `p2026` VALUES LESS THAN (2027))"],
            MySqlDdl.Build(Orders, new AddPartition(new("p2026", "VALUES LESS THAN (2027)"))));
    }

    [Fact]
    public void AddsAHashPartitionByCount()
    {
        Assert.Equal(["ALTER TABLE `shop`.`orders` ADD PARTITION PARTITIONS 1"], MySqlDdl.Build(Orders, new AddPartition(new("p4", string.Empty))));
    }

    [Fact]
    public void DropsAndTruncatesAPartitionButNotASubpartition()
    {
        Assert.Equal(["ALTER TABLE `shop`.`orders` DROP PARTITION `p2024`"], MySqlDdl.Build(Orders, new DropPartition(new PartitionInfo("p2024"))));
        Assert.Equal(["ALTER TABLE `shop`.`orders` TRUNCATE PARTITION `p2024`"], MySqlDdl.Build(Orders, new TruncatePartition(new PartitionInfo("p2024"))));
        Assert.Empty(MySqlDdl.Build(Orders, new DropPartition(new PartitionInfo("p2024sp0") { Parent = "p2024" })));
    }

    [Fact]
    public void SetsEveryChangedOptionInOneStatement()
    {
        var sql = MySqlDdl.Build(Orders, new SetTableOptions(
        [
            new(TableOptionNames.Comment, null, "Orders' table"),
            new(TableOptionNames.Engine, "MyISAM", "InnoDB"),
            new(TableOptionNames.Collation, null, "utf8mb4_0900_ai_ci"),
            new(TableOptionNames.Charset, null, "utf8mb4"),
            new(TableOptionNames.RowFormat, null, "dynamic"),
            new(TableOptionNames.AutoIncrement, null, "1000"),
        ]));

        Assert.Equal(
            [
                "ALTER TABLE `shop`.`orders` ENGINE = InnoDB, DEFAULT CHARSET = utf8mb4, COLLATE = utf8mb4_0900_ai_ci, ROW_FORMAT = DYNAMIC, "
                + "AUTO_INCREMENT = 1000, COMMENT = 'Orders'' table'",
            ],
            sql);
    }

    [Fact]
    public void ClearingTheCommentAndRowFormatWritesTheirDefaults()
    {
        var sql = MySqlDdl.Build(Orders, new SetTableOptions([new(TableOptionNames.Comment, "old", null), new(TableOptionNames.RowFormat, "Compact", null)]));

        Assert.Equal(["ALTER TABLE `shop`.`orders` ROW_FORMAT = DEFAULT, COMMENT = ''"], sql);
    }

    [Theory]
    [InlineData(TableOptionNames.Engine, "InnoDB; DROP TABLE x")]
    [InlineData(TableOptionNames.Engine, null)]
    [InlineData(TableOptionNames.AutoIncrement, "0")]
    [InlineData(TableOptionNames.AutoIncrement, "-5")]
    public void RefusesOptionValuesTheGrammarCannotTake(string option, string? value)
    {
        Assert.Throws<ArgumentException>(() => MySqlDdl.Build(Orders, new SetTableOptions([new(option, "x", value)])));
    }

    [Fact]
    public void ReadsTheCharsetFromTheCollation()
    {
        var options = MySqlDdl.ReadOptions("InnoDB", "utf8mb4_0900_ai_ci", "Dynamic", 42, string.Empty);

        Assert.Contains(new TableOption(TableOptionNames.Charset, "utf8mb4"), options);
        Assert.Contains(new TableOption(TableOptionNames.AutoIncrement, "42"), options);
        Assert.Contains(new TableOption(TableOptionNames.Comment, null), options);
    }

    [Fact]
    public void FoldsPartitionRowsAndPutsTheBoundSyntaxBack()
    {
        var partitioning = MySqlDdl.Partitioning(
        [
            new("p2024", "p2024sp0", "RANGE COLUMNS", "`year`", "2025", 1, 1, 10, 16384, "HASH", "`id`"),
            new("p2024", "p2024sp1", "RANGE COLUMNS", "`year`", "2025", 1, 2, 12, 16384, "HASH", "`id`"),
            new("pmax", "pmaxsp0", "RANGE COLUMNS", "`year`", "MAXVALUE", 2, 1, 0, 16384, "HASH", "`id`"),
        ]);

        Assert.NotNull(partitioning);
        Assert.Equal("RANGE COLUMNS", partitioning.Method);
        Assert.Equal("`year`", partitioning.Key);
        Assert.Equal("HASH (`id`)", partitioning.Subpartitioning);
        Assert.Equal(["p2024", "p2024sp0", "p2024sp1", "pmax", "pmaxsp0"], partitioning.Partitions.Select(p => p.Name));
        Assert.Equal("VALUES LESS THAN (2025)", partitioning.Partitions[0].Bound);
        Assert.True(partitioning.Partitions[0].IsSubpartitioned);
        Assert.Equal("p2024", partitioning.Partitions[1].Parent);
        Assert.Equal(12, partitioning.Partitions[2].RowEstimate);
    }

    [Theory]
    [InlineData("LIST", "1,2,3", "VALUES IN (1,2,3)")]
    [InlineData("RANGE", "MAXVALUE", "VALUES LESS THAN (MAXVALUE)")]
    [InlineData("HASH", null, null)]
    [InlineData("KEY", "", null)]
    public void SpellsBoundsByMethod(string method, string? description, string? expected)
    {
        Assert.Equal(expected, MySqlDdl.Bound(method, description));
    }

    [Fact]
    public void AnUnpartitionedTableHasNoPartitioning()
    {
        Assert.Null(MySqlDdl.Partitioning([]));
    }
}
