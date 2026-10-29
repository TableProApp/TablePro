using TablePro.Core.Browse;
using TablePro.Core.Import;
using TablePro.Core.Schema;

namespace TablePro.Drivers.Sqlite.Tests;

/// <summary>The import's write modes against a real table: the key probe, updates, inserts and what each leaves alone.</summary>
public sealed class SqliteImportTests
{
    private static readonly ObjectName Items = new(null, "items");

    private static CancellationToken Ct => TestContext.Current.CancellationToken;

    private static async Task<SqliteDatabase> CreateAsync()
    {
        var db = await SqliteDatabase.CreateAsync(Ct);
        await db.RunAsync(
            [
                "CREATE TABLE items (id INTEGER PRIMARY KEY AUTOINCREMENT, code TEXT NOT NULL UNIQUE, name TEXT, qty INTEGER NOT NULL DEFAULT 0)",
                "INSERT INTO items (code, name, qty) VALUES ('A', 'Apple', 1), ('B', 'Banana', 2)",
            ],
            Ct);
        return db;
    }

    private static ImportRowBuilder Builder(params string[] columns) =>
        new(columns.ToDictionary(c => c, c => c), columns.ToDictionary(c => c, c => c is "id" or "qty" ? typeof(long) : typeof(string)));

    private static async IAsyncEnumerable<IReadOnlyDictionary<string, object?>> Records(params (string Field, object? Value)[][] rows)
    {
        foreach (var row in rows)
        {
            await Task.Yield();
            yield return row.ToDictionary(p => p.Field, p => p.Value);
        }
    }

    private static ImportRowWriting Writing(ImportWriteMode mode, params string[] kept) => new(mode, ["code"], kept);

    private static async Task<Dictionary<string, (long Id, string? Name, long Qty)>> RowsAsync(SqliteDatabase db)
    {
        var result = await db.Session.BrowseAsync(new BrowseRequest(Items, BrowseFilter.None, [new SortColumn("id", false)], 0, 100), Ct);
        var rows = new Dictionary<string, (long, string?, long)>(StringComparer.Ordinal);
        for (var i = 0; i < result.Rows.Count; i++)
        {
            rows[(string)result[i, 1]!] = ((long)result[i, 0]!, result[i, 2] as string, (long)result[i, 3]!);
        }

        return rows;
    }

    [Fact]
    public async Task UpsertUpdatesMatchedRowsInsertsTheRestAndKeepsUnmappedColumns()
    {
        await using var db = await CreateAsync();

        var result = await RowImporter.ImportAsync(
            db.Session, Items, Records([("code", "A"), ("name", "Apricot")], [("code", "C"), ("name", "Cherry")]), Builder("code", "name"), Writing(ImportWriteMode.Upsert), null, Ct);

        Assert.Equal((1L, 1L, 1L, 0L), (result.Matched, result.Updated, result.Inserted, result.Unmatched + result.Existing));
        var rows = await RowsAsync(db);
        Assert.Equal((1L, "Apricot", 1L), rows["A"]);
        Assert.Equal((2L, "Banana", 2L), rows["B"]);
        Assert.Equal("Cherry", rows["C"].Name);
        Assert.Equal(0L, rows["C"].Qty);
    }

    [Fact]
    public async Task UpdateLeavesOutRowsWhoseKeyIsNotInTheTable()
    {
        await using var db = await CreateAsync();

        var result = await RowImporter.ImportAsync(
            db.Session, Items, Records([("code", "B"), ("name", "Blueberry")], [("code", "Z"), ("name", "Zucchini")]), Builder("code", "name"), Writing(ImportWriteMode.Update), null, Ct);

        Assert.Equal((1L, 0L, 1L), (result.Updated, result.Inserted, result.Unmatched));
        var rows = await RowsAsync(db);
        Assert.Equal("Blueberry", rows["B"].Name);
        Assert.False(rows.ContainsKey("Z"));
    }

    [Fact]
    public async Task InsertSkippingExistingAddsOnlyNewKeys()
    {
        await using var db = await CreateAsync();

        var result = await RowImporter.ImportAsync(
            db.Session, Items, Records([("code", "A"), ("name", "Avocado")], [("code", "D"), ("name", "Date")]), Builder("code", "name"), Writing(ImportWriteMode.InsertSkippingExisting), null, Ct);

        Assert.Equal((0L, 1L, 1L), (result.Updated, result.Inserted, result.Existing));
        var rows = await RowsAsync(db);
        Assert.Equal("Apple", rows["A"].Name);
        Assert.Equal("Date", rows["D"].Name);
    }

    [Fact]
    public async Task ARepeatedKeySeesTheWriteOfItsFirstOccurrence()
    {
        await using var db = await CreateAsync();

        var result = await RowImporter.ImportAsync(
            db.Session, Items, Records([("code", "E"), ("name", "first")], [("code", "E"), ("name", "second")]), Builder("code", "name"), Writing(ImportWriteMode.Upsert), null, Ct);

        Assert.Equal((1L, 1L), (result.Inserted, result.Updated));
        Assert.Equal("second", (await RowsAsync(db))["E"].Name);
    }

    [Fact]
    public async Task AnIdentityColumnIsWrittenIntoInsertedRowsButNeverUpdated()
    {
        await using var db = await CreateAsync();

        await RowImporter.ImportAsync(
            db.Session, Items, Records([("id", "99"), ("code", "A"), ("qty", "7")], [("id", "50"), ("code", "F"), ("qty", "3")]), Builder("id", "code", "qty"), Writing(ImportWriteMode.Upsert, "id"), null, Ct);

        var rows = await RowsAsync(db);
        Assert.Equal((1L, "Apple", 7L), rows["A"]);
        Assert.Equal(50L, rows["F"].Id);
    }

    [Fact]
    public async Task AKeyMatchingSeveralRowsStopsTheImportBeforeItsBatchIsWritten()
    {
        await using var db = await CreateAsync();
        await db.RunAsync(["UPDATE items SET name = 'same'"], Ct);

        var error = await Assert.ThrowsAsync<InvalidOperationException>(() => RowImporter.ImportAsync(
            db.Session, Items, Records([("name", "same"), ("qty", "9")]), Builder("name", "qty"), new ImportRowWriting(ImportWriteMode.Update, ["name"], []), null, Ct));

        Assert.Contains("matched 2 rows", error.Message, StringComparison.Ordinal);
        Assert.All((await RowsAsync(db)).Values, r => Assert.NotEqual(9L, r.Qty));
    }

    [Fact]
    public async Task AFailedImportLeavesTheTableAsItWas()
    {
        await using var db = await CreateAsync();
        await RefuseCodeAsync(db, "BAD");

        // The refused row comes after a whole batch, which a batch-at-a-time import would already have committed.
        await Assert.ThrowsAnyAsync<Exception>(() => RowImporter.ImportAsync(
            db.Session, Items, NewCodes(RowImporter.BatchSize + 10, ("BAD", "refused")), Builder("code", "name"), ImportRowWriting.Insert, null, Ct));

        Assert.True(RowImporter.RunsInOneTransaction(db.Session, ImportRowWriting.Insert));
        Assert.Equal(2, await db.Session.CountAsync(Items, BrowseFilter.None, Ct));
    }

    [Fact]
    public async Task WithoutOneTransactionTheBatchesBeforeAFailureStay()
    {
        await using var db = await CreateAsync();
        await RefuseCodeAsync(db, "BAD");
        var writing = ImportRowWriting.Insert with { SingleTransaction = false };

        await Assert.ThrowsAnyAsync<Exception>(() => RowImporter.ImportAsync(
            db.Session, Items, NewCodes(RowImporter.BatchSize + 10, ("BAD", "refused")), Builder("code", "name"), writing, null, Ct));

        Assert.False(RowImporter.RunsInOneTransaction(db.Session, writing));
        Assert.Equal(2 + RowImporter.BatchSize, await db.Session.CountAsync(Items, BrowseFilter.None, Ct));
    }

    [Fact]
    public async Task MatchingSeesRowsAnEarlierBatchWroteInTheSameImport()
    {
        await using var db = await CreateAsync();

        // N0 is inserted in the first batch and uncommitted when the second batch counts it; a probe outside the
        // transaction would miss it and insert it again, which the UNIQUE code refuses.
        var result = await RowImporter.ImportAsync(
            db.Session, Items, NewCodes(RowImporter.BatchSize, ("N0", "again")), Builder("code", "name"), Writing(ImportWriteMode.Upsert), null, Ct);

        Assert.Equal((RowImporter.BatchSize, 1L), (result.Inserted, result.Updated));
        Assert.Equal("again", (await RowsAsync(db))["N0"].Name);
        Assert.Equal(2 + RowImporter.BatchSize, await db.Session.CountAsync(Items, BrowseFilter.None, Ct));
    }

    [Fact]
    public async Task AFailedUpsertTakesBackItsUpdatesAndInserts()
    {
        await using var db = await CreateAsync();
        await RefuseCodeAsync(db, "BAD");

        await Assert.ThrowsAnyAsync<Exception>(() => RowImporter.ImportAsync(
            db.Session, Items, Records([("code", "A"), ("name", "Avocado")], [("code", "C"), ("name", "Cherry")], [("code", "BAD"), ("name", "refused")]),
            Builder("code", "name"), Writing(ImportWriteMode.Upsert), null, Ct));

        var rows = await RowsAsync(db);
        Assert.Equal("Apple", rows["A"].Name);
        Assert.False(rows.ContainsKey("C"));
    }

    private static async Task RefuseCodeAsync(SqliteDatabase db, string code)
    {
        var results = await db.RunAsync([$"CREATE TRIGGER refuse_code BEFORE INSERT ON items WHEN NEW.code = '{code}' BEGIN SELECT RAISE(ABORT, 'refused'); END"], Ct);
        Assert.All(results, r => Assert.True(r.Succeeded, r.Error));
    }

    private static async IAsyncEnumerable<IReadOnlyDictionary<string, object?>> NewCodes(int count, params (string Code, string Name)[] then)
    {
        for (var i = 0; i < count; i++)
        {
            await Task.Yield();
            yield return new Dictionary<string, object?> { ["code"] = $"N{i}", ["name"] = $"New {i}" };
        }

        foreach (var (code, name) in then)
        {
            yield return new Dictionary<string, object?> { ["code"] = code, ["name"] = name };
        }
    }

    [Fact]
    public async Task ProbeCountsKeysInOneRoundTrip()
    {
        await using var db = await CreateAsync();
        var matcher = Assert.IsAssignableFrom<IImportRowMatcher>(db.Session);

        var counts = await matcher.CountKeyMatchesAsync(Items, ["code"], [["B"], ["missing"], ["A"], [null]], Ct);

        Assert.Equal([1L, 0L, 1L, 0L], counts);
    }
}
