using TablePro.Core.Browse;
using TablePro.Core.Drivers;
using TablePro.Core.Editing;
using TablePro.Core.Schema;

namespace TablePro.Drivers.Sqlite.Tests;

public sealed class SqliteSessionTests
{
    private static readonly ObjectName Books = new(null, "books");
    private static readonly ObjectName Authors = new(null, "authors");

    private static CancellationToken Ct => TestContext.Current.CancellationToken;

    [Fact]
    public async Task ConnectsAndReportsVersion()
    {
        await using var db = await SqliteDatabase.CreateAsync(Ct);

        await db.Session.PingAsync(Ct);
        Assert.StartsWith("3.", db.Session.ServerVersion, StringComparison.Ordinal);
        Assert.Equal("main", db.Session.DefaultSchema);
        Assert.Contains("main", await db.Session.GetSchemasAsync(Ct));
    }

    [Fact]
    public async Task RunsStartupCommandsOnEveryConnection()
    {
        await using var db = await SqliteDatabase.CreateAsync(Ct, "PRAGMA user_version = 7; PRAGMA cache_size = -4000;");

        var results = await db.RunAsync(["PRAGMA cache_size"], Ct);

        Assert.Equal(-4000L, results[0].ResultSets[0][0, 0]);
    }

    [Fact]
    public async Task ListsTablesAndViews()
    {
        await using var db = await SqliteDatabase.CreateAsync(Ct);

        var objects = await db.Session.GetObjectsAsync(null, Ct);

        Assert.Contains(objects, o => o.Name == Authors && o.Kind == ObjectKind.Table);
        Assert.Contains(objects, o => o.Name == Books && o.Kind == ObjectKind.Table);
        Assert.Contains(objects, o => o.Name.Name == "cheap_books" && o.Kind == ObjectKind.View);
        Assert.DoesNotContain(objects, o => o.Name.Name.StartsWith("sqlite_", StringComparison.Ordinal));
    }

    [Fact]
    public async Task ReadsColumnsKeysIndexesForeignKeysAndTriggers()
    {
        await using var db = await SqliteDatabase.CreateAsync(Ct);

        var structure = await db.Session.GetStructureAsync(Books, Ct);

        Assert.Equal(["id", "author_id", "title", "price"], structure.Columns.Select(c => c.Name));
        var id = structure.Columns[0];
        Assert.True(id.IsPrimaryKey);
        Assert.True(id.IsIdentity);
        Assert.False(structure.Columns[1].IsNullable);
        Assert.Equal("0", structure.Columns[3].DefaultValue);
        Assert.Equal(["id"], structure.PrimaryKey);

        var index = Assert.Single(structure.Indexes, i => i.Name == "ix_books_title");
        Assert.Equal(["title", "price"], index.Columns);
        Assert.False(index.IsUnique);
        Assert.Contains(structure.Indexes, i => i.IsPrimary && i.Columns.SequenceEqual(["id"]));

        var key = Assert.Single(structure.ForeignKeys);
        Assert.Equal("fk_books_author", key.Name);
        Assert.Equal(["author_id"], key.Columns);
        Assert.Equal(Authors, key.ReferencedTable);
        Assert.Equal(["id"], key.ReferencedColumns);
        Assert.Equal("CASCADE", key.OnDelete);

        var trigger = Assert.Single(structure.Triggers);
        Assert.Equal("trg_books_ai", trigger.Name);
        Assert.Equal("AFTER", trigger.Timing);
        Assert.Equal("INSERT", trigger.Event);

        var authors = await db.Session.GetStructureAsync(Authors, Ct);
        Assert.Contains(authors.Indexes, i => i.IsUnique && i.Columns.SequenceEqual(["email"]));
    }

    [Fact]
    public async Task ReturnsDefinitions()
    {
        await using var db = await SqliteDatabase.CreateAsync(Ct);

        var table = await db.Session.GetDefinitionAsync(new DatabaseObject(Books, ObjectKind.Table), Ct);
        var view = await db.Session.GetDefinitionAsync(new DatabaseObject(new ObjectName(null, "cheap_books"), ObjectKind.View), Ct);

        Assert.StartsWith("CREATE TABLE books", table, StringComparison.Ordinal);
        Assert.Contains("CREATE INDEX ix_books_title", table, StringComparison.Ordinal);
        Assert.Contains("CREATE TRIGGER trg_books_ai", table, StringComparison.Ordinal);
        Assert.StartsWith("CREATE VIEW cheap_books", view, StringComparison.Ordinal);
    }

    [Fact]
    public async Task BrowsesWithFilterSortAndPaging()
    {
        await using var db = await SqliteDatabase.CreateAsync(Ct);
        var filter = new BrowseFilter([new FilterRule("price", FilterOperator.GreaterThan, "6")]);

        var page = await db.Session.BrowseAsync(new BrowseRequest(Books, filter, [new SortColumn("price", Descending: true)], Offset: 1, Limit: 2), Ct);
        var count = await db.Session.CountAsync(Books, filter, Ct);

        Assert.Equal(4, count);
        Assert.Equal(2, page.RowCount);
        var title = page.ColumnIndex("title");
        Assert.Equal("Gamma", page[0, title]);
        Assert.Equal("Beta", page[1, title]);
    }

    [Fact]
    public async Task SearchesEveryColumnCaseInsensitively()
    {
        await using var db = await SqliteDatabase.CreateAsync(Ct);
        var filter = new BrowseFilter([new FilterRule(null, FilterOperator.Contains, "ALP")]) { SearchColumns = ["title"] };

        Assert.Equal(1, await db.Session.CountAsync(Books, filter, Ct));
    }

    [Fact]
    public async Task SavesUpdatesInsertsAndDeletesInOneTransaction()
    {
        await using var db = await SqliteDatabase.CreateAsync(Ct);
        RowChange[] changes =
        [
            new RowUpdate(Key(1), new Dictionary<string, object?> { ["title"] = "Alpha 2" }),
            new RowInsert(new Dictionary<string, object?> { ["id"] = 10, ["author_id"] = 1, ["title"] = "New", ["price"] = 1.5 }),
            new RowDelete(Key(5)),
        ];

        var affected = await db.Session.SaveChangesAsync(Books, changes, Ct);

        Assert.Equal(3, affected);
        Assert.Equal(5, await db.Session.CountAsync(Books, BrowseFilter.None, Ct));
        var renamed = await db.Session.CountAsync(Books, new BrowseFilter([new FilterRule("title", FilterOperator.Equals, "Alpha 2")]), Ct);
        Assert.Equal(1, renamed);
    }

    [Fact]
    public async Task RollsBackEverythingWhenAChangeMissesItsRow()
    {
        await using var db = await SqliteDatabase.CreateAsync(Ct);
        RowChange[] changes =
        [
            new RowDelete(Key(1)),
            new RowUpdate(Key(999), new Dictionary<string, object?> { ["title"] = "Ghost" }),
        ];

        var error = await Assert.ThrowsAsync<RowCountMismatchException>(() => db.Session.SaveChangesAsync(Books, changes, Ct));

        Assert.Equal(0, error.Actual);
        Assert.Equal(5, await db.Session.CountAsync(Books, BrowseFilter.None, Ct));
    }

    [Fact]
    public async Task ChannelRunsMultipleResultSetsAndStopsAtTheFirstError()
    {
        await using var db = await SqliteDatabase.CreateAsync(Ct);

        var results = await db.RunAsync(
            ["SELECT 1 AS a; SELECT 2 AS b, 3 AS c", "INSERT INTO authors (name) VALUES ('Dee')", "SELECT * FROM missing_table", "SELECT 4"],
            Ct);

        Assert.Equal(3, results.Count);
        Assert.Equal(2, results[0].ResultSets.Count);
        Assert.Equal("c", results[0].ResultSets[1].Columns[1].Name);
        Assert.Equal(1, results[1].RecordsAffected);
        Assert.False(results[2].Succeeded);
        Assert.Contains("missing_table", results[2].Error, StringComparison.Ordinal);
    }

    [Fact]
    public async Task ChannelKeepsSessionStateBetweenRuns()
    {
        await using var db = await SqliteDatabase.CreateAsync(Ct);
        await using var channel = await db.Session.OpenChannelAsync(Ct);

        await foreach (var _ in channel.ExecuteAsync(["CREATE TEMP TABLE scratch (x)", "INSERT INTO scratch VALUES (42)"], new(), Ct))
        {
        }

        var values = new List<object?>();
        await foreach (var result in channel.ExecuteAsync(["SELECT x FROM scratch"], new(), Ct))
        {
            values.Add(result.ResultSets[0][0, 0]);
        }

        Assert.Equal([42L], values);
    }

    [Fact]
    public async Task OpensReadOnlyWhenTheProfileForbidsWrites()
    {
        await using var db = await SqliteDatabase.CreateAsync(Ct);
        var profile = db.Session.Profile with { SafeMode = Core.Connections.SafeModeLevel.ReadOnly };
        await using var readOnly = await new SqliteDriver().ConnectAsync(ConnectionRequest.Direct(profile, null), Ct);
        await using var channel = await readOnly.OpenChannelAsync(Ct);

        var results = new List<Core.Results.StatementResult>();
        await foreach (var result in channel.ExecuteAsync(["DELETE FROM books"], new(), Ct))
        {
            results.Add(result);
        }

        Assert.False(results[0].Succeeded);
    }

    private static Dictionary<string, object?> Key(long id) => new() { ["id"] = id };
}
