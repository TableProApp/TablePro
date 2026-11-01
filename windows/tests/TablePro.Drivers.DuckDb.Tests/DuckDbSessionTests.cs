using TablePro.Core.Browse;
using TablePro.Core.Connections;
using TablePro.Core.Drivers;
using TablePro.Core.Editing;
using TablePro.Core.Results;
using TablePro.Core.Schema;

namespace TablePro.Drivers.DuckDb.Tests;

public sealed class DuckDbSessionTests
{
    private static readonly ObjectName Books = new("main", "books");
    private static readonly ObjectName Authors = new("main", "authors");

    private static CancellationToken Ct => TestContext.Current.CancellationToken;

    [Fact]
    public async Task ConnectsAndReportsCatalog()
    {
        await using var db = await DuckDbDatabase.CreateAsync(Ct);

        await db.Session.PingAsync(Ct);
        Assert.False(string.IsNullOrEmpty(db.Session.ServerVersion));
        Assert.Equal("main", db.Session.DefaultSchema);
        Assert.Contains(db.Session.CurrentDatabase!, await db.Session.GetDatabasesAsync(Ct));
        Assert.Contains("main", await db.Session.GetSchemasAsync(Ct));
    }

    [Fact]
    public async Task RunsStartupCommands()
    {
        await using var db = await DuckDbDatabase.CreateAsync(Ct, "SET VARIABLE answer = 42;");

        var results = await db.RunAsync(["SELECT getvariable('answer')"], Ct);

        Assert.True(results[0].Succeeded, results[0].Error);
        Assert.Equal(42, Convert.ToInt32(results[0].ResultSets[0][0, 0], System.Globalization.CultureInfo.InvariantCulture));
    }

    [Fact]
    public async Task ListsTablesViewsSequencesAndMacros()
    {
        await using var db = await DuckDbDatabase.CreateAsync(Ct);

        var objects = await db.Session.GetObjectsAsync("main", Ct);

        Assert.Contains(objects, o => o.Name == Books && o.Kind == ObjectKind.Table && o.RowEstimate == 5);
        Assert.Contains(objects, o => o.Name.Name == "cheap_books" && o.Kind == ObjectKind.View);
        Assert.Contains(objects, o => o.Name.Name == "authors_id_seq" && o.Kind == ObjectKind.Sequence);
        Assert.Contains(objects, o => o.Name.Name == "add_tax" && o.Kind == ObjectKind.Function);
    }

    [Fact]
    public async Task ReadsColumnsKeysIndexesAndForeignKeys()
    {
        await using var db = await DuckDbDatabase.CreateAsync(Ct);

        var structure = await db.Session.GetStructureAsync(Books, Ct);

        Assert.Equal(["id", "author_id", "title", "price"], structure.Columns.Select(c => c.Name));
        Assert.True(structure.Columns[0].IsPrimaryKey);
        Assert.False(structure.Columns[1].IsNullable);
        Assert.Equal("DECIMAL(10,2)", structure.Columns[3].DataType);
        Assert.Equal("Display title", structure.Columns[2].Comment);
        Assert.Equal(["id"], structure.PrimaryKey);

        Assert.Contains(structure.Indexes, i => i.IsPrimary && i.Columns.SequenceEqual(["id"]));
        var index = Assert.Single(structure.Indexes, i => i.Name == "ix_books_title");
        Assert.Equal(["title", "price"], index.Columns);
        Assert.False(index.IsUnique);

        var key = Assert.Single(structure.ForeignKeys);
        Assert.Equal(["author_id"], key.Columns);
        Assert.Equal(Authors, key.ReferencedTable);
        Assert.Equal(["id"], key.ReferencedColumns);

        var authors = await db.Session.GetStructureAsync(Authors, Ct);
        Assert.True(authors.Columns[0].IsIdentity);
        Assert.Contains(authors.Indexes, i => i.IsUnique && !i.IsPrimary && i.Columns.SequenceEqual(["email"]));
        Assert.Empty(authors.ForeignKeys);
    }

    [Fact]
    public async Task ReturnsDefinitions()
    {
        await using var db = await DuckDbDatabase.CreateAsync(Ct);

        var table = await db.Session.GetDefinitionAsync(new DatabaseObject(Books, ObjectKind.Table), Ct);
        var view = await db.Session.GetDefinitionAsync(new DatabaseObject(new ObjectName("main", "cheap_books"), ObjectKind.View), Ct);
        var sequence = await db.Session.GetDefinitionAsync(new DatabaseObject(new ObjectName("main", "authors_id_seq"), ObjectKind.Sequence), Ct);
        var macro = await db.Session.GetDefinitionAsync(new DatabaseObject(new ObjectName("main", "add_tax"), ObjectKind.Function), Ct);

        Assert.StartsWith("CREATE TABLE", table, StringComparison.OrdinalIgnoreCase);
        Assert.Contains("ix_books_title", table, StringComparison.Ordinal);
        Assert.StartsWith("CREATE OR REPLACE VIEW", view, StringComparison.Ordinal);
        Assert.StartsWith("CREATE SEQUENCE", sequence, StringComparison.OrdinalIgnoreCase);
        Assert.StartsWith("CREATE OR REPLACE MACRO \"main\".\"add_tax\"(p) AS", macro, StringComparison.Ordinal);
    }

    [Fact]
    public async Task BrowsesWithFilterSortAndPaging()
    {
        await using var db = await DuckDbDatabase.CreateAsync(Ct);
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
        await using var db = await DuckDbDatabase.CreateAsync(Ct);
        var filter = new BrowseFilter([new FilterRule(null, FilterOperator.Contains, "ALP")]) { SearchColumns = ["title", "price"] };

        Assert.Equal(1, await db.Session.CountAsync(Books, filter, Ct));
    }

    [Fact]
    public async Task SavesUpdatesInsertsAndDeletesInOneTransaction()
    {
        await using var db = await DuckDbDatabase.CreateAsync(Ct);
        RowChange[] changes =
        [
            new RowUpdate(Key(1), new Dictionary<string, object?> { ["price"] = 6.5m }),
            new RowInsert(new Dictionary<string, object?> { ["id"] = 10, ["author_id"] = 1, ["title"] = "New", ["price"] = 1.5m }),
            new RowDelete(Key(5)),
        ];

        var affected = await db.Session.SaveChangesAsync(Books, changes, Ct);

        Assert.Equal(3, affected);
        Assert.Equal(5, await db.Session.CountAsync(Books, BrowseFilter.None, Ct));
        Assert.Equal(1, await db.Session.CountAsync(Books, new BrowseFilter([new FilterRule("price", FilterOperator.Equals, "6.5")]), Ct));
    }

    [Fact]
    public async Task RollsBackEverythingWhenAChangeMissesItsRow()
    {
        await using var db = await DuckDbDatabase.CreateAsync(Ct);
        RowChange[] changes =
        [
            new RowDelete(Key(5)),
            new RowUpdate(Key(999), new Dictionary<string, object?> { ["title"] = "Ghost" }),
        ];

        var error = await Assert.ThrowsAsync<RowCountMismatchException>(() => db.Session.SaveChangesAsync(Books, changes, Ct));

        Assert.Equal(0, error.Actual);
        Assert.Equal(5, await db.Session.CountAsync(Books, BrowseFilter.None, Ct));
    }

    [Fact]
    public async Task ChannelRunsMultipleResultSetsAndStopsAtTheFirstError()
    {
        await using var db = await DuckDbDatabase.CreateAsync(Ct);

        var results = await db.RunAsync(
            ["SELECT 1 AS a; SELECT 2 AS b, 3 AS c", "INSERT INTO notes VALUES (3, 'three')", "SELECT * FROM missing_table", "SELECT 4"],
            Ct);

        Assert.Equal(3, results.Count);
        Assert.True(results[0].Succeeded, results[0].Error);
        Assert.Equal(2, results[0].ResultSets.Count);
        Assert.Equal("c", results[0].ResultSets[1].Columns[1].Name);
        Assert.True(results[1].Succeeded, results[1].Error);
        Assert.False(results[2].Succeeded);
        Assert.Contains("missing_table", results[2].Error, StringComparison.Ordinal);
    }

    [Fact]
    public async Task ReportsSettings()
    {
        await using var db = await DuckDbDatabase.CreateAsync(Ct);

        var settings = await Assert.IsAssignableFrom<IServerVariablesProvider>(db.Session).GetVariablesAsync(Ct);

        Assert.True(settings.RowCount > 10);
        Assert.Equal("name", settings.Columns[0].Name);
    }

    [Fact]
    public async Task OpensReadOnlyWhenTheProfileForbidsWrites()
    {
        var path = await DuckDbDatabase.CreateFileAsync(Ct);
        try
        {
            var profile = new ConnectionProfile { Name = "ro", Engine = DatabaseEngine.DuckDb, FilePath = path, SafeMode = SafeModeLevel.ReadOnly };
            Assert.Contains("access_mode=READ_ONLY", DuckDbConnectionStringFactory.Build(ConnectionRequest.Direct(profile, null)), StringComparison.Ordinal);

            await using var session = await new DuckDbDriver().ConnectAsync(ConnectionRequest.Direct(profile, null), Ct);
            await using var channel = await session.OpenChannelAsync(Ct);
            var results = new List<StatementResult>();
            await foreach (var result in channel.ExecuteAsync(["DELETE FROM notes"], new(), Ct))
            {
                results.Add(result);
            }

            Assert.False(results[0].Succeeded);
        }
        finally
        {
            DuckDbDatabase.DeleteFile(path);
        }
    }

    private static Dictionary<string, object?> Key(int id) => new() { ["id"] = id };
}
