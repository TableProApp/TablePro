namespace TablePro.Interop.Tests;

public sealed class RowEditTests
{
    private static readonly TableName People = new(null, "people");

    [Fact]
    public async Task AnUpdateAnInsertAndADeleteSaveAndTheTableReadsThemBack()
    {
        var cancellationToken = TestContext.Current.CancellationToken;
        await using var database = await SqliteDatabase.CreateAsync();
        using var editor = await database.Session.OpenTableEditorAsync(People, refresh: false, cancellationToken);
        using var page = await PageAsync(database, cancellationToken);

        using var save = editor.Plan(page.Rows,
        [
            new RowEdit.Update(0, [new CellChange(2, new CellEdit.Text("first"))]),
            new RowEdit.Insert([CellEdit.ServerDefault.Instance, new CellEdit.Text("Edsger"), CellEdit.Null.Instance]),
            new RowEdit.Delete(1),
        ]);
        var outcome = await save.RunAsync(confirmed: false, cancellationToken);
        var names = await ReadAsync(database, "SELECT name || ':' || coalesce(note, 'NULL') FROM people ORDER BY id", cancellationToken);

        Assert.Equal(SaveGate.Run, save.Gate);
        Assert.Equal(3, save.Statements.Count);
        Assert.Equal(["'first'", "1"], save.Statements[0].Values);
        Assert.StartsWith("INSERT", save.Statements[1].Sql, StringComparison.Ordinal);
        Assert.StartsWith("DELETE", save.Statements[2].Sql, StringComparison.Ordinal);
        Assert.Equal(["2"], save.Statements[2].Values);
        Assert.Equal(new RowSaveOutcome.Saved(3), outcome);
        Assert.Equal(["Ada:first", "Zoë 👋:中文", "Edsger:NULL"], names);
    }

    [Fact]
    public async Task TheEditorStartsFromTheWholeValueAndANewRowFromTheServersValues()
    {
        var cancellationToken = TestContext.Current.CancellationToken;
        await using var database = await SqliteDatabase.CreateAsync();
        using var editor = await database.Session.OpenTableEditorAsync(People, refresh: false, cancellationToken);
        using var page = await PageAsync(database, cancellationToken);

        var note = editor.GetEditStart(page.Rows, 1, 2);
        var none = editor.GetEditStart(page.Rows, 0, 2);

        Assert.Null(editor.Lock);
        Assert.Equal(new EditStart.Editable("line one\nline two", false), note);
        Assert.Equal(new EditStart.Editable(string.Empty, true), none);
        Assert.Equal([CellEdit.ServerDefault.Instance, CellEdit.Null.Instance, CellEdit.Null.Instance], editor.Columns.Select(column => column.NewRow));
        Assert.True(editor.Columns[0].PrimaryKey);
        Assert.False(editor.Columns[0].Editable);
        Assert.True(editor.Columns[1].TakesEmpty);
        Assert.Null(editor.LockFor(page.Rows));
    }

    [Fact]
    public async Task TextTheColumnCannotHoldIsRefusedWithItsCode()
    {
        var cancellationToken = TestContext.Current.CancellationToken;
        await using var database = await SqliteDatabase.CreateAsync();
        await database.ExecuteAsync("ALTER TABLE people ADD COLUMN age INTEGER");
        using var editor = await database.Session.OpenTableEditorAsync(People, refresh: false, cancellationToken);

        var number = editor.Check(3, new CellEdit.Text("one"), newRow: false);
        var required = editor.Check(1, CellEdit.Null.Instance, newRow: false);
        var key = editor.Check(0, new CellEdit.Text("7"), newRow: false);
        var fine = editor.Check(3, new CellEdit.Text("7"), newRow: false);

        Assert.Equal("edit.invalid_integer", number?.Code);
        Assert.Equal("edit.required", required?.Code);
        Assert.Equal("edit.not_editable", key?.Code);
        Assert.Null(fine);
    }

    [Fact]
    public async Task ACellEditedBackToItsValueSavesNothing()
    {
        var cancellationToken = TestContext.Current.CancellationToken;
        await using var database = await SqliteDatabase.CreateAsync();
        using var editor = await database.Session.OpenTableEditorAsync(People, refresh: false, cancellationToken);
        using var page = await PageAsync(database, cancellationToken);

        using var save = editor.Plan(page.Rows, [new RowEdit.Update(2, [new CellChange(1, new CellEdit.Text("Zoë 👋"))])]);

        Assert.True(save.IsEmpty);
        Assert.Empty(save.Statements);
    }

    [Fact]
    public async Task ARowThatChangedUnderTheSaveRollsBackAndNamesItsEdit()
    {
        var cancellationToken = TestContext.Current.CancellationToken;
        await using var database = await SqliteDatabase.CreateAsync();
        using var editor = await database.Session.OpenTableEditorAsync(People, refresh: false, cancellationToken);
        using var page = await PageAsync(database, cancellationToken);
        await database.ExecuteAsync("DELETE FROM people WHERE id = 3");

        using var save = editor.Plan(page.Rows,
        [
            new RowEdit.Update(0, [new CellChange(2, new CellEdit.Text("kept back"))]),
            new RowEdit.Update(2, [new CellChange(2, new CellEdit.Text("gone"))]),
        ]);
        var outcome = await save.RunAsync(confirmed: false, cancellationToken);
        var notes = await ReadAsync(database, "SELECT coalesce(note, 'NULL') FROM people WHERE id = 1", cancellationToken);

        var rolledBack = Assert.IsType<RowSaveOutcome.RolledBack>(outcome);
        Assert.Equal("driver.row_guard_failed", rolledBack.Error.Code);
        Assert.Equal(1, rolledBack.Edit);
        Assert.Equal(["NULL"], notes);
    }

    [Fact]
    public async Task AReadOnlyFileLocksEveryRowAndATableWithNoKeyToo()
    {
        var cancellationToken = TestContext.Current.CancellationToken;
        await using var database = await SqliteDatabase.CreateAsync();
        await database.ExecuteAsync("CREATE TABLE notes (body TEXT)");
        using var notes = await database.Session.OpenTableEditorAsync(new TableName(null, "notes"), refresh: false, cancellationToken);
        await using var readOnly = await database.Core.OpenFileAsync(new FileOpenOptions(database.Path, ReadOnly: true), cancellationToken);
        using var locked = await readOnly.OpenTableEditorAsync(People, refresh: false, cancellationToken);

        Assert.Equal(EditLock.NoPrimaryKey, notes.Lock);
        Assert.Equal(EditLock.ReadOnlyConnection, locked.Lock);
    }

    private static async Task<Page> PageAsync(SqliteDatabase database, CancellationToken cancellationToken)
    {
        var page = await database.Session.ReadTablePageAsync(People, null, null, 100, cancellationToken: cancellationToken);
        var run = page.Run;
        Assert.IsType<QueryOutcome.Completed>(await run.Completion);
        return new Page(run, run.GetResultSet(0) ?? throw new InvalidOperationException("The page read no set."));
    }

    private static async Task<List<string?>> ReadAsync(SqliteDatabase database, string sql, CancellationToken cancellationToken)
    {
        using var run = database.Editor.Run(sql, cancellationToken: cancellationToken);
        Assert.IsType<QueryOutcome.Completed>(await run.Completion);
        using var set = run.GetResultSet(0) ?? throw new InvalidOperationException("The read held no set.");
        return [.. Enumerable.Range(0, (int)set.RowCount).Select(row => set.GetCellText(row, 0))];
    }

    private sealed class Page(QueryRun run, ResultSet rows) : IDisposable
    {
        public ResultSet Rows { get; } = rows;

        public void Dispose()
        {
            Rows.Dispose();
            run.Dispose();
        }
    }
}
