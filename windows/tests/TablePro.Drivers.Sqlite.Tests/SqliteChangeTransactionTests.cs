using TablePro.Core.Browse;
using TablePro.Core.Compare;
using TablePro.Core.Drivers;
using TablePro.Core.Editing;
using TablePro.Core.Import;
using TablePro.Core.Schema;

namespace TablePro.Drivers.Sqlite.Tests;

/// <summary>One transaction across tables, against real SQLite files: a multi-table sync and an import that empties its table first.</summary>
public sealed class SqliteChangeTransactionTests
{
    private static readonly ObjectName Authors = new(null, "authors");
    private static readonly ObjectName Books = new(null, "books");

    private static CancellationToken Ct => TestContext.Current.CancellationToken;

    private static TableCompareRequest Request(ObjectName table) => new(new ComparedTablePair(table, table), CompareTableScope.Default);

    private static Task<long> CountAsync(SqliteDatabase db, ObjectName table) => db.Session.CountAsync(table, BrowseFilter.None, Ct);

    /// <summary>A new author and two of their books on the source; the target refuses the second book when <paramref name="refuse"/> is set.</summary>
    private static async Task<(SqliteDatabase Source, SqliteDatabase Target, CombinedSyncPlan Plan)> NewAuthorAndBooksAsync(bool refuse)
    {
        var source = await SqliteDatabase.CreateAsync(Ct);
        var target = await SqliteDatabase.CreateAsync(Ct);
        await source.RunAsync(
            [
                "INSERT INTO authors (id, name, email) VALUES (4, 'Dee', 'dee@example.com')",
                "INSERT INTO books (id, author_id, title, price) VALUES (6, 4, 'Zeta', 3), (7, 4, 'Eta', 4)",
            ],
            Ct);
        if (refuse)
        {
            await target.RunAsync(["CREATE TRIGGER refuse_eta BEFORE INSERT ON books WHEN NEW.title = 'Eta' BEGIN SELECT RAISE(ABORT, 'refused'); END"], Ct);
        }

        var options = DataCompareOptions.Default;
        var outcomes = await new MultiTableComparer(source.Session, target.Session, options).CompareAllAsync([Request(Authors), Request(Books)], cancellationToken: Ct);
        var plan = CombinedSyncPlan.Build([.. outcomes.Select(o => new CombinedSyncInput(o.Result!, null, o.SourceStructure))], options);
        return (source, target, plan);
    }

    [Fact]
    public async Task TheSessionOffersTransactionsAcrossTables()
    {
        await using var db = await SqliteDatabase.CreateAsync(Ct);
        Assert.NotNull(ChangeTransactions.For(db.Session));
    }

    [Fact]
    public async Task AFailedMultiTableSyncRollsEveryTableBack()
    {
        var (source, target, plan) = await NewAuthorAndBooksAsync(refuse: true);
        await using var sourceDb = source;
        await using var targetDb = target;
        Assert.Equal(["authors", "books"], plan.Segments.Select(s => s.Table.Name));

        var applied = await DataSyncApplier.ApplyAsync(target.Session, plan, cancellationToken: Ct);

        // The author's insert ran first and committed on its own before; now the refused book takes it back with it.
        Assert.False(applied.Succeeded);
        Assert.Equal((0, 0), (applied.AppliedSteps, applied.CommittedBatches));
        Assert.Equal(3, await CountAsync(target, Authors));
        Assert.Equal(5, await CountAsync(target, Books));
    }

    [Fact]
    public async Task AMultiTableSyncCommitsOnceAndMatches()
    {
        var (source, target, plan) = await NewAuthorAndBooksAsync(refuse: false);
        await using var sourceDb = source;
        await using var targetDb = target;
        var progress = new List<DataSyncProgress>();

        var applied = await DataSyncApplier.ApplyAsync(target.Session, plan, progress: new SyncProgress(progress), cancellationToken: Ct);

        Assert.True(applied.Succeeded, applied.Error?.Message);
        Assert.Equal((3, 3, 1, 1), (applied.AppliedSteps, applied.RowsAffected, applied.CommittedBatches, applied.TotalBatches));
        Assert.Equal(new DataSyncProgress(3, 3), progress[^1]);
        Assert.Equal(4, await CountAsync(target, Authors));
        Assert.Equal(7, await CountAsync(target, Books));
    }

    [Fact]
    public async Task BatchesCommitAcrossTablesAndKeepWhatCommitted()
    {
        var (source, target, plan) = await NewAuthorAndBooksAsync(refuse: true);
        await using var sourceDb = source;
        await using var targetDb = target;

        var applied = await DataSyncApplier.ApplyAsync(target.Session, plan, new DataSyncApplyOptions(BatchSize: 2, SingleTransaction: false), cancellationToken: Ct);

        // The first batch holds the author and the first book across two tables; the second batch, the refused book, rolls back alone.
        Assert.False(applied.Succeeded);
        Assert.Equal((2, 1, 2), (applied.AppliedSteps, applied.CommittedBatches, applied.TotalBatches));
        Assert.Equal(4, await CountAsync(target, Authors));
        Assert.Equal(6, await CountAsync(target, Books));
    }

    [Fact]
    public async Task ATransactionLeftUncommittedRollsBack()
    {
        await using var db = await SqliteDatabase.CreateAsync(Ct);
        var transactions = ChangeTransactions.For(db.Session)!;

        await using (var transaction = await transactions.BeginChangesAsync(Ct))
        {
            await transaction.SaveChangesAsync(Authors, [new RowInsert(new Dictionary<string, object?> { ["name"] = "Eve" })], Ct);
            Assert.Equal(5, await transaction.DeleteAllRowsAsync(Books, Ct));
        }

        Assert.Equal(3, await CountAsync(db, Authors));
        Assert.Equal(5, await CountAsync(db, Books));
    }

    [Fact]
    public async Task AKeyedChangeThatMissesItsRowFailsInsideTheTransaction()
    {
        await using var db = await SqliteDatabase.CreateAsync(Ct);
        await using var transaction = await ChangeTransactions.For(db.Session)!.BeginChangesAsync(Ct);

        await Assert.ThrowsAsync<RowCountMismatchException>(() => transaction.SaveChangesAsync(
            Books, [new RowDelete(new Dictionary<string, object?> { ["id"] = 99 })], Ct));
    }

    [Fact]
    public async Task DeletingExistingRowsFirstReplacesTheTable()
    {
        await using var db = await SqliteDatabase.CreateAsync(Ct);

        var result = await RowImporter.ImportAsync(db.Session, Books, Records(10, 11), BookBuilder(), ImportRowWriting.ReplaceRows, null, Ct);

        Assert.Equal(2, result.Inserted);
        var rows = await db.Session.BrowseAsync(new BrowseRequest(Books, BrowseFilter.None, [new SortColumn("id", false)], 0, 100), Ct);
        Assert.Equal([10L, 11L], Enumerable.Range(0, rows.Rows.Count).Select(i => (long)rows[i, 0]!));
    }

    [Fact]
    public async Task AFailedImportAfterDeletingKeepsTheOldRows()
    {
        await using var db = await SqliteDatabase.CreateAsync(Ct);

        // The second record repeats the first one's key, which fails after the table was emptied and the first row written.
        await Assert.ThrowsAnyAsync<Exception>(() => RowImporter.ImportAsync(db.Session, Books, Records(10, 10), BookBuilder(), ImportRowWriting.ReplaceRows, null, Ct));

        Assert.Equal(5, await CountAsync(db, Books));
    }

    [Fact]
    public async Task DeletingExistingRowsIsRefusedForAModeThatMatchesRows()
    {
        await using var db = await SqliteDatabase.CreateAsync(Ct);
        var writing = new ImportRowWriting(ImportWriteMode.Upsert, ["id"], [], DeleteExistingRows: true);

        await Assert.ThrowsAsync<InvalidOperationException>(() => RowImporter.ImportAsync(db.Session, Books, Records(10), BookBuilder(), writing, null, Ct));
        Assert.Equal(5, await CountAsync(db, Books));
    }

    private static ImportRowBuilder BookBuilder()
    {
        string[] columns = ["id", "author_id", "title"];
        return new(columns.ToDictionary(c => c, c => c), columns.ToDictionary(c => c, c => c == "title" ? typeof(string) : typeof(long)));
    }

    private static async IAsyncEnumerable<IReadOnlyDictionary<string, object?>> Records(params int[] ids)
    {
        foreach (var id in ids)
        {
            await Task.Yield();
            yield return new Dictionary<string, object?> { ["id"] = id, ["author_id"] = 1, ["title"] = $"Book {id}" };
        }
    }

    private sealed class SyncProgress(List<DataSyncProgress> reports) : IProgress<DataSyncProgress>
    {
        public void Report(DataSyncProgress value) => reports.Add(value);
    }
}
