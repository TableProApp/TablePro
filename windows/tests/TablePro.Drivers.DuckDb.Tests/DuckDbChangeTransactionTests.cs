using TablePro.Core.Browse;
using TablePro.Core.Drivers;
using TablePro.Core.Editing;
using TablePro.Core.Import;
using TablePro.Core.Schema;

namespace TablePro.Drivers.DuckDb.Tests;

/// <summary>One transaction across tables against a real DuckDB file, as a multi-table sync and an import that empties its table use it.</summary>
public sealed class DuckDbChangeTransactionTests
{
    private static readonly ObjectName Authors = new(null, "authors");
    private static readonly ObjectName Notes = new(null, "notes");

    private static CancellationToken Ct => TestContext.Current.CancellationToken;

    private static Task<long> CountAsync(DuckDbDatabase db, ObjectName table) => db.Session.CountAsync(table, BrowseFilter.None, Ct);

    private static RowInsert Note(int id, string body) => new(new Dictionary<string, object?> { ["id"] = id, ["body"] = body });

    [Fact]
    public async Task WritesToSeveralTablesCommitTogether()
    {
        await using var db = await DuckDbDatabase.CreateAsync(Ct);
        var transactions = ChangeTransactions.For(db.Session);
        Assert.NotNull(transactions);

        await using (var transaction = await transactions.BeginChangesAsync(Ct))
        {
            await transaction.SaveChangesAsync(Authors, [new RowInsert(new Dictionary<string, object?> { ["id"] = 4, ["name"] = "Dee" })], Ct);
            await transaction.SaveChangesAsync(Notes, [Note(3, "three")], Ct);
            await transaction.CommitAsync(Ct);
        }

        Assert.Equal(4, await CountAsync(db, Authors));
        Assert.Equal(3, await CountAsync(db, Notes));
    }

    [Fact]
    public async Task AFailureInTheSecondTableTakesTheFirstBack()
    {
        await using var db = await DuckDbDatabase.CreateAsync(Ct);

        await using (var transaction = await ChangeTransactions.For(db.Session)!.BeginChangesAsync(Ct))
        {
            await transaction.SaveChangesAsync(Notes, [Note(3, "three")], Ct);

            // Author 1 exists, so the primary key refuses the insert; nothing is committed.
            await Assert.ThrowsAnyAsync<Exception>(() => transaction.SaveChangesAsync(
                Authors, [new RowInsert(new Dictionary<string, object?> { ["id"] = 1, ["name"] = "Again" })], Ct));
        }

        Assert.Equal(3, await CountAsync(db, Authors));
        Assert.Equal(2, await CountAsync(db, Notes));
    }

    [Fact]
    public async Task DeletingExistingRowsFirstReplacesTheTableInOneTransaction()
    {
        await using var db = await DuckDbDatabase.CreateAsync(Ct);
        var builder = new ImportRowBuilder(
            new Dictionary<string, string> { ["id"] = "id", ["body"] = "body" },
            new Dictionary<string, Type> { ["id"] = typeof(int), ["body"] = typeof(string) });

        var result = await RowImporter.ImportAsync(db.Session, Notes, Records(("9", "nine")), builder, ImportRowWriting.ReplaceRows, null, Ct);

        Assert.Equal(1, result.Inserted);
        var rows = await db.Session.BrowseAsync(new BrowseRequest(Notes, BrowseFilter.None, [], 0, 10), Ct);
        Assert.Equal("nine", Assert.Single(Enumerable.Range(0, rows.Rows.Count).Select(i => rows[i, 1] as string)));
    }

    [Fact]
    public async Task APlainImportThatFailsLeavesTheTableAsItWas()
    {
        await using var db = await DuckDbDatabase.CreateAsync(Ct);

        // Author 1 exists, so the last row fails after a whole batch was written.
        await Assert.ThrowsAnyAsync<Exception>(() => RowImporter.ImportAsync(
            db.Session, Authors, NewAuthors(100, RowImporter.BatchSize + 10, ("1", "Again")), AuthorBuilder(), ImportRowWriting.Insert, null, Ct));

        Assert.Equal(3, await CountAsync(db, Authors));
    }

    [Fact]
    public async Task MatchingSeesRowsAnEarlierBatchWroteInTheSameImport()
    {
        await using var db = await DuckDbDatabase.CreateAsync(Ct);
        var writing = new ImportRowWriting(ImportWriteMode.Upsert, ["id"], []);

        var result = await RowImporter.ImportAsync(
            db.Session, Authors, NewAuthors(100, RowImporter.BatchSize, ("100", "again")), AuthorBuilder(), writing, null, Ct);

        Assert.Equal((RowImporter.BatchSize, 1L), (result.Inserted, result.Updated));
        Assert.Equal(3 + RowImporter.BatchSize, await CountAsync(db, Authors));
        var row = await db.Session.BrowseAsync(new BrowseRequest(Authors, new BrowseFilter([], "id = 100"), [], 0, 10), Ct);
        Assert.Equal("again", row[0, 1] as string);
    }

    private static ImportRowBuilder AuthorBuilder() => new(
        new Dictionary<string, string> { ["id"] = "id", ["name"] = "name" },
        new Dictionary<string, Type> { ["id"] = typeof(int), ["name"] = typeof(string) });

    private static async IAsyncEnumerable<IReadOnlyDictionary<string, object?>> NewAuthors(int firstId, int count, params (string Id, string Name)[] then)
    {
        for (var i = 0; i < count; i++)
        {
            await Task.Yield();
            yield return new Dictionary<string, object?> { ["id"] = (firstId + i).ToString(System.Globalization.CultureInfo.InvariantCulture), ["name"] = $"Author {i}" };
        }

        foreach (var (id, name) in then)
        {
            yield return new Dictionary<string, object?> { ["id"] = id, ["name"] = name };
        }
    }

    private static async IAsyncEnumerable<IReadOnlyDictionary<string, object?>> Records(params (string Id, string Body)[] rows)
    {
        foreach (var (id, body) in rows)
        {
            await Task.Yield();
            yield return new Dictionary<string, object?> { ["id"] = id, ["body"] = body };
        }
    }
}
