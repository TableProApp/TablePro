using Microsoft.Data.Sqlite;
using TablePro.Core.Browse;
using TablePro.Core.Connections;
using TablePro.Core.Copy;
using TablePro.Core.Drivers;
using TablePro.Core.Generation;
using TablePro.Core.Results;
using TablePro.Core.Schema;

namespace TablePro.Drivers.Sqlite.Tests;

/// <summary>The object copy and the row generator against real SQLite files, through the driver's own DDL and saves.</summary>
public sealed class SqliteCopyAndGenerationTests
{
    private static CancellationToken Ct => TestContext.Current.CancellationToken;

    private static async Task<(IDatabaseSession Session, string Path)> EmptyAsync()
    {
        var path = Path.Combine(Path.GetTempPath(), $"tablepro-copy-{Guid.NewGuid():N}.db");
        await using (var connection = new SqliteConnection($"Data Source={path};Pooling=False"))
        {
            await connection.OpenAsync(Ct);
        }

        var profile = new ConnectionProfile { Name = "target", Engine = DatabaseEngine.Sqlite, FilePath = path };
        return (await new SqliteDriver().ConnectAsync(ConnectionRequest.Direct(profile, null), Ct), path);
    }

    private static async Task<List<StatementResult>> RunAsync(IDatabaseSession session, string sql)
    {
        await using var channel = await session.OpenChannelAsync(Ct);
        var results = new List<StatementResult>();
        await foreach (var result in channel.ExecuteAsync([sql], new ExecuteOptions(), Ct))
        {
            results.Add(result);
        }

        return results;
    }

    [Fact]
    public async Task CopiesTablesRowsKeysIndexesAndAViewIntoAnEmptyDatabase()
    {
        await using var source = await SqliteDatabase.CreateAsync(Ct);
        var (target, path) = await EmptyAsync();
        try
        {
            var objects = await source.Session.GetObjectsAsync(source.Session.DefaultSchema, Ct);
            var picked = objects.Where(o => o.Name.Name is "books" or "authors" or "cheap_books").ToArray();
            var request = new CopyRequest(source.Session, picked, target, target.DefaultSchema) { BatchSize = 2 };

            var plan = await CopyPlanner.PlanAsync(request, Ct);
            var result = await CopyRunner.RunAsync(request, plan, null, Ct);

            Assert.True(result.Succeeded, string.Join("; ", result.Outcomes.Select(o => $"{o.Name}: {o.Error}")));
            Assert.Equal(["authors", "books"], plan.Tables.Select(t => t.Target.Name));
            Assert.Equal(8, result.RowsCopied);
            var books = await target.GetStructureAsync(new ObjectName(target.DefaultSchema, "books"), Ct);
            var key = Assert.Single(books.ForeignKeys);
            Assert.Equal("authors", key.ReferencedTable.Name);
            Assert.Contains(books.Indexes, i => i.Name == "ix_books_title");
            var cheap = await RunAsync(target, "SELECT COUNT(*) FROM cheap_books");
            Assert.Equal(2L, Convert.ToInt64(cheap[0].ResultSets[0][0, 0], System.Globalization.CultureInfo.InvariantCulture));
        }
        finally
        {
            await target.DisposeAsync();
            SqliteConnection.ClearAllPools();
            File.Delete(path);
        }
    }

    [Fact]
    public async Task AddingRowsToAnExistingTableKeepsItsRows()
    {
        await using var source = await SqliteDatabase.CreateAsync(Ct);
        await using var target = await SqliteDatabase.CreateAsync(Ct);
        await target.RunAsync(["DELETE FROM books WHERE id > 2"], Ct);
        await source.RunAsync(["UPDATE books SET id = id + 10"], Ct);
        var books = (await source.Session.GetObjectsAsync(source.Session.DefaultSchema, Ct)).Single(o => o.Name.Name == "books");
        var request = new CopyRequest(source.Session, [books], target.Session, target.Session.DefaultSchema, CopyContent.Data, CopyExistingPolicy.AppendData);

        var result = await CopyRunner.RunAsync(request, await CopyPlanner.PlanAsync(request, Ct), null, Ct);

        Assert.True(result.Succeeded, string.Join("; ", result.Outcomes.Select(o => o.Error)));
        Assert.Equal(7, await target.Session.CountAsync(new ObjectName(target.Session.DefaultSchema, "books"), BrowseFilter.None, Ct));
    }

    [Fact]
    public async Task GeneratesRowsThatReferenceExistingParents()
    {
        await using var db = await SqliteDatabase.CreateAsync(Ct);
        var table = new ObjectName(db.Session.DefaultSchema, "books");
        var target = await RowGenerationLoader.LoadAsync(db.Session, table, Ct);
        var settings = RowGenerationDefaults.ForTable(target.Model, new DateOnly(2026, 1, 1), 42, 120);
        Assert.Empty(RowGenerationValidation.Issues(settings, target.Model));

        var written = await RowGenerationWriter.InsertAsync(db.Session, target, new RowGenerationEngine(target.Model, settings, target.NullsAreDistinct), 120, null, Ct, batchSize: 50);

        Assert.Equal(120, written);
        var page = await db.Session.BrowseAsync(new BrowseRequest(table, BrowseFilter.None, [new SortColumn("id", false)], 0, 1000), Ct);
        Assert.Equal(125, page.RowCount);
        var authorIds = page.Rows.Select(r => Convert.ToInt64(r[page.ColumnIndex("author_id")], System.Globalization.CultureInfo.InvariantCulture)).ToHashSet();
        Assert.Subset(new HashSet<long> { 1, 2, 3 }, authorIds);
    }
}
