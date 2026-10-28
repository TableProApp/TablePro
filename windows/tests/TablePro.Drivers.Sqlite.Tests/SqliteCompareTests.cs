using TablePro.Core.Compare;
using TablePro.Core.Drivers;
using TablePro.Core.Editing;
using TablePro.Core.Rewind;
using TablePro.Core.Schema;

namespace TablePro.Drivers.Sqlite.Tests;

/// <summary>Compare, Sync and Rewind end to end against real SQLite files through the driver.</summary>
public sealed class SqliteCompareTests
{
    private static readonly ObjectName Books = new(null, "books");

    private static CancellationToken Ct => TestContext.Current.CancellationToken;

    private static async Task<DataDiffResult> CompareBooksAsync(IDatabaseSession source, IDatabaseSession target, DataCompareOptions options)
    {
        var setup = DataCompareSetup.Create(await source.GetStructureAsync(Books, Ct), await target.GetStructureAsync(Books, Ct));
        var spec = setup.Spec!;
        return await new DataDiffEngine(spec, options).CompareAsync(
            SessionRowSource.Source(source, spec, options, Ct),
            SessionRowSource.Target(target, spec, options, Ct),
            cancellationToken: Ct);
    }

    [Fact]
    public async Task SyncMakesTwoDatabasesMatch()
    {
        await using var source = await SqliteDatabase.CreateAsync(Ct);
        await using var target = await SqliteDatabase.CreateAsync(Ct);
        await target.RunAsync(
            [
                "UPDATE books SET title = 'Beta (old)', price = 11.5 WHERE id = 2",
                "DELETE FROM books WHERE id = 4",
                "INSERT INTO books (id, author_id, title, price) VALUES (9, 1, 'Extra', 1)",
            ],
            Ct);
        var options = DataCompareOptions.Default with { ChunkSize = 2, DeleteExtraRows = true };

        var result = await CompareBooksAsync(source.Session, target.Session, options);

        Assert.Equal((1L, 1L, 1L, 3L), (result.OnlyInSourceCount, result.OnlyInTargetCount, result.ChangedCount, result.IdenticalCount));
        var changed = result.Differences.Single(d => d.Kind == RowDiffKind.Changed);
        Assert.Equal(["title", "price"], changed.ChangedColumns.Select(i => result.Spec.Columns[i].Source));

        var plan = DataSyncPlan.Build(result, options);
        var applied = await DataSyncApplier.ApplyAsync(target.Session, plan, cancellationToken: Ct);
        Assert.True(applied.Succeeded, applied.Error?.Message);

        var again = await CompareBooksAsync(source.Session, target.Session, options);
        Assert.Equal(0, again.DifferenceCount);
        Assert.Equal(5, again.IdenticalCount);
    }

    [Fact]
    public async Task FailedSyncRollsTheTargetBack()
    {
        await using var source = await SqliteDatabase.CreateAsync(Ct);
        await using var target = await SqliteDatabase.CreateAsync(Ct);
        await source.RunAsync(["INSERT INTO books (id, author_id, title, price) VALUES (7, 1, 'Ok', 1), (8, 1, 'Bad', 1)"], Ct);
        await target.RunAsync(
            [
                "DELETE FROM books WHERE id = 1",
                "CREATE TRIGGER refuse_bad BEFORE INSERT ON books WHEN NEW.title = 'Bad' BEGIN SELECT RAISE(ABORT, 'refused'); END",
            ],
            Ct);

        var result = await CompareBooksAsync(source.Session, target.Session, DataCompareOptions.Default);
        var applied = await DataSyncApplier.ApplyAsync(target.Session, DataSyncPlan.Build(result, DataCompareOptions.Default), cancellationToken: Ct);

        // The target's trigger refuses the last insert, which takes the first two back with it.
        Assert.False(applied.Succeeded);
        var count = await target.Session.CountAsync(Books, Core.Browse.BrowseFilter.None, Ct);
        Assert.Equal(4, count);
    }

    [Fact]
    public async Task SchemaCompareScriptsTheTargetsMissingColumn()
    {
        await using var source = await SqliteDatabase.CreateAsync(Ct);
        await using var target = await SqliteDatabase.CreateAsync(Ct);
        await source.RunAsync(["ALTER TABLE books ADD COLUMN isbn TEXT"], Ct);

        var diffs = SchemaDiffEngine.Compare([await source.Session.GetStructureAsync(Books, Ct)], [await target.Session.GetStructureAsync(Books, Ct)]);
        var script = SchemaMigrationBuilder.Build(diffs, (ISchemaDdlProvider)target.Session, null);
        await target.RunAsync([.. script.Statements.Select(s => s.Sql)], Ct);

        var after = SchemaDiffEngine.Compare([await source.Session.GetStructureAsync(Books, Ct)], [await target.Session.GetStructureAsync(Books, Ct)]);
        Assert.Equal(SchemaDiffKind.Identical, Assert.Single(after).Kind);
    }

    [Fact]
    public async Task RewindPutsASavedEditBack()
    {
        await using var db = await SqliteDatabase.CreateAsync(Ct);
        var structure = await db.Session.GetStructureAsync(Books, Ct);
        var page = await db.Session.BrowseAsync(new Core.Browse.BrowseRequest(Books, Core.Browse.BrowseFilter.None, [new Core.Browse.SortColumn("id", false)], 0, 100), Ct);
        var buffer = new TableEditBuffer(page, structure.PrimaryKey);
        buffer.SetValue(0, page.ColumnIndex("title"), "Alpha 2");
        buffer.ToggleDelete([4]);
        await db.Session.SaveChangesAsync(Books, buffer.BuildChanges(), Ct);
        var record = RewindCapture.FromBuffer(buffer, structure.PrimaryKey, Guid.NewGuid(), db.Session.Profile.Engine, db.Session.CurrentDatabase, Books, DateTimeOffset.UtcNow)!;

        await db.Session.SaveChangesAsync(Books, RewindPlanner.Plan(record).Changes, Ct);

        var restored = await db.Session.BrowseAsync(new Core.Browse.BrowseRequest(Books, Core.Browse.BrowseFilter.None, [new Core.Browse.SortColumn("id", false)], 0, 100), Ct);
        Assert.Equal(5, restored.RowCount);
        Assert.Equal("Alpha", restored[0, restored.ColumnIndex("title")]);
        Assert.Equal("Epsilon", restored[4, restored.ColumnIndex("title")]);
    }
}
