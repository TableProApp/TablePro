using Google.Cloud.Spanner.Data;
using TablePro.Core.Browse;
using TablePro.Core.Connections;
using TablePro.Core.Editing;
using TablePro.Core.Schema;
using TablePro.Core.Sql;
using TablePro.Drivers.Spanner;

namespace TablePro.Drivers.Warehouse.Tests;

public sealed class SpannerTests
{
    private static readonly ObjectName Singers = new(string.Empty, "Singers");

    [Fact]
    public void DatabasePathComesFromTheHost()
    {
        var settings = SpannerSettings.From(Profiles.Request(DatabaseEngine.Spanner, host: "projects/p1/instances/i1/databases/d1", database: null, filePath: @"C:\keys\sa.json"));

        Assert.Equal("projects/p1/instances/i1/databases/d1", settings.DatabasePath);
        Assert.Equal("d1", settings.DatabaseId);
        Assert.False(settings.UsesEmulator);
        var builder = settings.ToConnectionStringBuilder();
        Assert.Equal("projects/p1/instances/i1/databases/d1", builder.DataSource);
        Assert.Equal(@"C:\keys\sa.json", builder.CredentialFile);
    }

    [Fact]
    public void InstancePathInTheHostTakesTheDatabaseField()
    {
        var settings = SpannerSettings.From(Profiles.Request(DatabaseEngine.Spanner, host: "projects/p1/instances/i1/", database: "shop"));

        Assert.Equal("projects/p1/instances/i1/databases/shop", settings.DatabasePath);
    }

    [Fact]
    public void ProjectAndInstanceOptionsWithTheDatabaseFieldAndTheEmulator()
    {
        var settings = SpannerSettings.From(Profiles.Request(
            DatabaseEngine.Spanner,
            host: "localhost",
            database: "shop",
            filePath: @"C:\keys\ignored.json",
            options: new Dictionary<string, string> { ["project"] = "test-project", ["instance"] = "test-instance", ["emulatorHost"] = "localhost:9020" }));

        Assert.Equal("projects/test-project/instances/test-instance/databases/shop", settings.DatabasePath);
        Assert.True(settings.UsesEmulator);
        var builder = settings.ToConnectionStringBuilder();
        Assert.Equal("localhost", builder.Host);
        Assert.Equal(9020, builder.Port);
        Assert.True(string.IsNullOrEmpty(builder.CredentialFile));
    }

    [Theory]
    [InlineData("localhost", null)]
    [InlineData("projects/p/instances/i/databases/d/extra", null)]
    [InlineData("projects//instances/i/databases/d", null)]
    public void IncompletePathsAreRefused(string host, string? database)
    {
        Assert.Throws<ArgumentException>(() => SpannerSettings.From(Profiles.Request(DatabaseEngine.Spanner, host: host, database: database)));
    }

    [Theory]
    [InlineData("CREATE TABLE t (id INT64) PRIMARY KEY (id)", SpannerStatementKind.Ddl)]
    [InlineData("  alter table t add column c STRING(MAX)", SpannerStatementKind.Ddl)]
    [InlineData("-- why\nDROP INDEX i", SpannerStatementKind.Ddl)]
    [InlineData("/* note */ CREATE VIEW v SQL SECURITY INVOKER AS SELECT 1", SpannerStatementKind.Ddl)]
    [InlineData("INSERT INTO t (id) VALUES (1)", SpannerStatementKind.Dml)]
    [InlineData("@{LOCK_SCANNED_RANGES=exclusive} UPDATE t SET a = 1 WHERE TRUE", SpannerStatementKind.Dml)]
    [InlineData("SELECT * FROM t", SpannerStatementKind.Query)]
    [InlineData("WITH x AS (SELECT 1) SELECT * FROM x", SpannerStatementKind.Query)]
    [InlineData("BEGIN", SpannerStatementKind.Begin)]
    [InlineData("start transaction", SpannerStatementKind.Begin)]
    [InlineData("COMMIT;", SpannerStatementKind.Commit)]
    [InlineData("ROLLBACK", SpannerStatementKind.Rollback)]
    public void RoutesDdlToTheAdminApi(string sql, SpannerStatementKind expected)
    {
        Assert.Equal(expected, SpannerSql.Classify(sql));
    }

    [Fact]
    public void CreateTablePutsThePrimaryKeyAfterTheColumns()
    {
        var ddl = SpannerSql.BuildDdl(Singers, new CreateTable(Singers, [
            new ColumnDefinition("SingerId", "INT64", IsNullable: false, IsPrimaryKey: true),
            new ColumnDefinition("Name", "STRING(MAX)", DefaultExpression: "'unknown'"),
        ]));

        Assert.Equal("CREATE TABLE `Singers` (\n  `SingerId` INT64 NOT NULL,\n  `Name` STRING(MAX) DEFAULT ('unknown')\n) PRIMARY KEY (`SingerId`)", Assert.Single(ddl));
    }

    [Fact]
    public void AlterColumnSplitsTypeAndDefault()
    {
        var ddl = SpannerSql.BuildDdl(Singers, new AlterColumn(
            new ColumnDefinition("Name", "STRING(100)", DefaultExpression: "'x'"),
            new ColumnDefinition("Name", "STRING(MAX)", IsNullable: false)));

        Assert.Equal(
            ["ALTER TABLE `Singers` ALTER COLUMN `Name` STRING(MAX) NOT NULL", "ALTER TABLE `Singers` ALTER COLUMN `Name` DROP DEFAULT"],
            ddl);
    }

    [Fact]
    public void UnsupportedChangesReturnNothing()
    {
        Assert.Empty(SpannerSql.BuildDdl(Singers, new RenameColumn("a", "b")));
        Assert.Empty(SpannerSql.BuildDdl(Singers, new AlterColumn(new ColumnDefinition("a", "INT64", Comment: "x"), new ColumnDefinition("a", "INT64", Comment: "y"))));
        Assert.Equal(["DELETE FROM `Singers` WHERE TRUE"], SpannerSql.BuildDdl(Singers, new TruncateTable()));
        Assert.Equal(["CREATE UNIQUE INDEX `ByName` ON `Singers` (`Name`)"], SpannerSql.BuildDdl(Singers, new CreateIndex(new IndexDefinition("ByName", ["Name"], IsUnique: true))));
    }

    [Fact]
    public void ParametersAreTypedByTheColumn()
    {
        var number = SpannerSql.Parameter("p0", "INT64", "42");
        var text = SpannerSql.Parameter("p1", "STRING(MAX)", "x");
        var time = SpannerSql.Parameter("p2", "TIMESTAMP", "2024-01-02T03:04:05Z");
        var array = SpannerSql.Parameter("p3", "ARRAY<INT64>", "[1]");
        var empty = SpannerSql.Parameter("p4", "DATE", null);

        Assert.Equal(SpannerDbType.Int64, number.SpannerDbType);
        Assert.Equal(42L, number.Value);
        Assert.Equal(SpannerDbType.String, text.SpannerDbType);
        Assert.Equal(new DateTime(2024, 1, 2, 3, 4, 5, DateTimeKind.Utc), time.Value);
        Assert.Equal(SpannerDbType.String, array.SpannerDbType);
        Assert.Equal(DBNull.Value, empty.Value);
        Assert.Throws<FormatException>(() => SpannerSql.Parameter("p5", "INT64", "many"));
    }

    [Fact]
    public void BrowseEscapesLikeWithBackslashAndBindsTypedValues()
    {
        var types = new Dictionary<string, string> { ["SingerId"] = "INT64", ["Name"] = "STRING(MAX)", ["Tags"] = "ARRAY<STRING(MAX)>" };
        var filter = new BrowseFilter([new FilterRule("SingerId", FilterOperator.In, "1, 2"), new FilterRule("Name", FilterOperator.StartsWith, "a_b")])
        {
            SearchColumns = ["Tags"],
        };
        var request = new BrowseRequest(Singers, filter with { Rules = [.. filter.Rules, new FilterRule(null, FilterOperator.Contains, "x")] }, [], 0, 100);

        var statement = SpannerSql.Browse(Singers, request, types);

        Assert.Equal(
            "SELECT * FROM `Singers` WHERE `SingerId` IN (@p0, @p1) AND LOWER(`Name`) LIKE LOWER(@p2) AND (LOWER(TO_JSON_STRING(`Tags`)) LIKE LOWER(@p3)) LIMIT 100 OFFSET 0",
            statement.Sql);
        Assert.Equal([1L, 2L, "a\\_b%", "%x%"], statement.Parameters.Select(p => p.Value));
    }

    [Fact]
    public void ChangeParametersMapBackToTheirColumns()
    {
        var update = new RowUpdate(
            new Dictionary<string, object?> { ["SingerId"] = 1L, ["Deleted"] = null, ["Region"] = "EU" },
            new Dictionary<string, object?> { ["Name"] = "x", ["Age"] = "30" });
        var spec = ChangeSqlBuilder.Build(SpannerDialect.Instance, Singers, update);

        Assert.Equal(["Name", "Age", "SingerId", "Region"], spec.Parameters.Select(p => SpannerSession.ColumnOf(update, spec, p.Key)));
    }

    [Fact]
    public void PicksTheTableAndItsIndexesFromTheDatabaseDdl()
    {
        string[] statements =
        [
            "CREATE TABLE Singers (\n  SingerId INT64 NOT NULL,\n) PRIMARY KEY(SingerId)",
            "CREATE TABLE Albums (\n  SingerId INT64 NOT NULL,\n) PRIMARY KEY(SingerId), INTERLEAVE IN PARENT Singers ON DELETE CASCADE",
            "CREATE INDEX AlbumsBySinger ON Albums(SingerId)",
            "CREATE UNIQUE NULL_FILTERED INDEX SingersByName ON `Singers` (Name)",
            "CREATE VIEW SingerNames SQL SECURITY INVOKER AS SELECT Name FROM Singers",
        ];

        Assert.Equal([statements[0], statements[3]], SpannerSql.PickDefinition(statements, Singers));
        Assert.Equal([statements[4]], SpannerSql.PickDefinition(statements, new ObjectName(null, "SingerNames")));
        Assert.Empty(SpannerSql.PickDefinition(statements, new ObjectName("", "Missing")));
    }
}
