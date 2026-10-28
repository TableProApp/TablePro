using TablePro.Core.Schema;
using TablePro.Drivers.ClickHouse;

namespace TablePro.Drivers.Analytics.Tests;

public sealed class ClickHouseDdlTests
{
    private static readonly ObjectName Events = new("db", "events");

    private static IReadOnlyList<string> Build(SchemaChange change) => ClickHouseDdl.Build(Events, change);

    [Fact]
    public void CreateTableIsAMergeTreeOrderedByThePrimaryKey()
    {
        var change = new CreateTable(Events,
        [
            new ColumnDefinition("id", "UInt64", IsPrimaryKey: true),
            new ColumnDefinition("name", "String"),
            new ColumnDefinition("score", "Nullable(Float64)", IsNullable: false, DefaultExpression: "0", Comment: "pts"),
        ]);

        Assert.Equal(
            ["CREATE TABLE `db`.`events`\n(\n    `id` UInt64,\n    `name` Nullable(String),\n    `score` Float64 DEFAULT 0 COMMENT 'pts'\n)\nENGINE = MergeTree\nORDER BY `id`"],
            Build(change));
    }

    [Fact]
    public void CreateTableWithoutKeyOrdersByNothingAndWithSeveralByATuple()
    {
        var none = ClickHouseDdl.CreateTable(new CreateTable(Events, [new ColumnDefinition("a", "Int32", IsNullable: false)]));
        var two = ClickHouseDdl.CreateTable(new CreateTable(Events,
            [new ColumnDefinition("a", "Int32", IsPrimaryKey: true), new ColumnDefinition("b", "Date", IsPrimaryKey: true)]));

        Assert.EndsWith("ORDER BY tuple()", none, StringComparison.Ordinal);
        Assert.EndsWith("ORDER BY (`a`, `b`)", two, StringComparison.Ordinal);
    }

    [Theory]
    [InlineData("String", true, false, "Nullable(String)")]
    [InlineData("Nullable(String)", false, false, "String")]
    [InlineData("Nullable(String)", true, true, "String")]
    [InlineData("LowCardinality(String)", true, false, "LowCardinality(Nullable(String))")]
    [InlineData("LowCardinality(Nullable(String))", false, false, "LowCardinality(String)")]
    public void NullabilityIsWrittenIntoTheType(string type, bool nullable, bool key, string expected)
    {
        Assert.Equal(expected, ClickHouseDdl.TypeFor(new ColumnDefinition("c", type, nullable, IsPrimaryKey: key)));
    }

    [Fact]
    public void AddDropAndRenameColumn()
    {
        Assert.Equal(
            ["ALTER TABLE `db`.`events` ADD COLUMN `note` Nullable(String) DEFAULT 'n/a' COMMENT 'why'"],
            Build(new AddColumn(new ColumnDefinition("note", "String", DefaultExpression: "'n/a'", Comment: "why"))));
        Assert.Equal(["ALTER TABLE `db`.`events` DROP COLUMN `note`"], Build(new DropColumn("note")));
        Assert.Equal(["ALTER TABLE `db`.`events` RENAME COLUMN `a` TO `b`"], Build(new RenameColumn("a", "b")));
    }

    [Fact]
    public void AlterColumnTypeIsAModify()
    {
        var change = new AlterColumn(new ColumnDefinition("n", "Int32", false), new ColumnDefinition("n", "Int64", false));

        Assert.Equal(["ALTER TABLE `db`.`events` MODIFY COLUMN `n` Int64"], Build(change));
    }

    [Fact]
    public void MakingAColumnNonNullableFillsItsNullsWithTheTypeDefault()
    {
        var change = new AlterColumn(new ColumnDefinition("n", "Nullable(Int32)", true), new ColumnDefinition("n", "Int32", false));

        Assert.Equal(
            [
                "ALTER TABLE `db`.`events` MODIFY COLUMN `n` Int32 DEFAULT defaultValueOfTypeName('Int32')",
                "ALTER TABLE `db`.`events` MODIFY COLUMN `n` REMOVE DEFAULT",
            ],
            Build(change));
    }

    [Fact]
    public void MakingAColumnNonNullableWithADefaultUsesIt()
    {
        var change = new AlterColumn(new ColumnDefinition("n", "Nullable(Int32)", true), new ColumnDefinition("n", "Int32", false, "7"));

        Assert.Equal(["ALTER TABLE `db`.`events` MODIFY COLUMN `n` Int32 DEFAULT 7"], Build(change));
    }

    [Fact]
    public void DefaultChangesAndRemovals()
    {
        var set = new AlterColumn(new ColumnDefinition("n", "String", false), new ColumnDefinition("n", "String", false, "'y'"));
        var removed = new AlterColumn(new ColumnDefinition("n", "String", false, "'x'"), new ColumnDefinition("n", "String", false));

        Assert.Equal(["ALTER TABLE `db`.`events` MODIFY COLUMN `n` String DEFAULT 'y'"], Build(set));
        Assert.Equal(["ALTER TABLE `db`.`events` MODIFY COLUMN `n` REMOVE DEFAULT"], Build(removed));
    }

    [Fact]
    public void CommentAndNameChangesFollowTheModify()
    {
        var change = new AlterColumn(new ColumnDefinition("n", "String", false), new ColumnDefinition("m", "String", false, Comment: "it's"));

        Assert.Equal(
            [
                "ALTER TABLE `db`.`events` COMMENT COLUMN `n` 'it\\'s'",
                "ALTER TABLE `db`.`events` RENAME COLUMN `n` TO `m`",
            ],
            Build(change));
    }

    [Fact]
    public void UnchangedColumnNeedsNothing()
    {
        Assert.Empty(Build(new AlterColumn(new ColumnDefinition("n", "String"), new ColumnDefinition("n", "String"))));
    }

    [Fact]
    public void IndexesAreSkippingIndexes()
    {
        Assert.Equal(
            [
                "ALTER TABLE `db`.`events` ADD INDEX `ix_name` `name` TYPE minmax GRANULARITY 1",
                "ALTER TABLE `db`.`events` MATERIALIZE INDEX `ix_name`",
            ],
            Build(new CreateIndex(new IndexDefinition("ix_name", ["name"]))));
        Assert.Equal(
            "ALTER TABLE `db`.`events` ADD INDEX `ix_two` (`a`, `b`) TYPE minmax GRANULARITY 1",
            Build(new CreateIndex(new IndexDefinition("ix_two", ["a", "b"], true)))[0]);
        Assert.Equal(["ALTER TABLE `db`.`events` DROP INDEX `ix_name`"], Build(new DropIndex("ix_name")));
    }

    [Fact]
    public void ForeignKeysHaveNoStatements()
    {
        Assert.Empty(Build(new AddForeignKey(new ForeignKeyDefinition("fk", ["a"], new ObjectName("db", "other"), ["id"]))));
        Assert.Empty(Build(new DropForeignKey("fk")));
    }

    [Fact]
    public void RenameStaysInTheSameDatabase()
    {
        Assert.Equal(["RENAME TABLE `db`.`events` TO `db`.`events_old`"], Build(new RenameTable("events_old")));
    }

    [Theory]
    [InlineData(ObjectKind.Table, null, "DROP TABLE `db`.`events`")]
    [InlineData(ObjectKind.Table, "Dictionary", "DROP DICTIONARY `db`.`events`")]
    [InlineData(ObjectKind.View, null, "DROP VIEW `db`.`events`")]
    [InlineData(ObjectKind.MaterializedView, null, "DROP VIEW `db`.`events`")]
    public void DropObjectByKind(ObjectKind kind, string? comment, string expected)
    {
        Assert.Equal([expected], Build(new DropObject(new DatabaseObject(Events, kind, null, comment))));
    }

    [Fact]
    public void DropOfAnUnknownKindHasNoStatement()
    {
        Assert.Empty(Build(new DropObject(new DatabaseObject(Events, ObjectKind.Function))));
    }

    [Fact]
    public void TruncateAndDatabaseStatements()
    {
        Assert.Equal(["TRUNCATE TABLE `db`.`events`"], Build(new TruncateTable()));
        Assert.Equal("CREATE DATABASE `new db`", ClickHouseDdl.CreateDatabase("new db"));
        Assert.Equal("DROP DATABASE `x``y`", ClickHouseDdl.DropDatabase("x`y"));
    }

    [Fact]
    public void DefinitionUsesShowCreate()
    {
        Assert.Equal("SHOW CREATE TABLE `db`.`events`", ClickHouseDdl.ShowCreate(new DatabaseObject(Events, ObjectKind.View)));
        Assert.Equal("SHOW CREATE DICTIONARY `db`.`events`", ClickHouseDdl.ShowCreate(new DatabaseObject(Events, ObjectKind.Table, null, "Dictionary")));
    }
}
