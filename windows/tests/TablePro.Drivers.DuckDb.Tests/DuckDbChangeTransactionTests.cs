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

    private static async IAsyncEnumerable<IReadOnlyDictionary<string, object?>> Records(params (string Id, string Body)[] rows)
    {
        foreach (var (id, body) in rows)
        {
            await Task.Yield();
            yield return new Dictionary<string, object?> { ["id"] = id, ["body"] = body };
        }
    }
}
