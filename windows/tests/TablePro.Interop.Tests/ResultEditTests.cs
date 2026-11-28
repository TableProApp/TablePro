namespace TablePro.Interop.Tests;

public sealed class ResultEditTests
{
    [Fact]
    public async Task AResultOfOneKeyedTableSavesItsEditsByTheResultsOwnColumns()
    {
        var cancellationToken = TestContext.Current.CancellationToken;
        await using var database = await SqliteDatabase.CreateAsync();
        const string sql = "SELECT note, id FROM people ORDER BY id";
        using var run = database.Editor.Run(sql, cancellationToken: cancellationToken);
        Assert.IsType<QueryOutcome.Completed>(await run.Completion);
        using var rows = run.GetResultSet(0) ?? throw new InvalidOperationException("The run held no set.");
        using var editor = await database.Session.OpenResultEditorAsync(sql, rows, cancellationToken);
        var copies = editor.CopiesExactly(rows, 0);

        editor.SetCell(rows, 0, 0, new CellEdit.Text("first"));
        editor.DeleteRows(rows, [2]);
        var outcome = await editor.SaveAsync(rows, confirmed: false, cancellationToken);
        using var after = database.Editor.Run("SELECT coalesce(note, 'NULL') FROM people ORDER BY id", cancellationToken: cancellationToken);
        Assert.IsType<QueryOutcome.Completed>(await after.Completion);
        using var notes = after.GetResultSet(0) ?? throw new InvalidOperationException("The read held no set.");

        Assert.Null(editor.Lock);
        Assert.True(copies);
        Assert.Equal(new TableName(null, "people"), editor.Table);
        Assert.Equal(["note", "id"], editor.Columns.Select(column => column.Name));
        Assert.True(editor.Columns[0].Editable);
        Assert.True(editor.Columns[1].PrimaryKey);
        Assert.Equal(new RowSaveOutcome.Saved(2), outcome);
        Assert.Equal(2, notes.RowCount);
        Assert.Equal("first", notes.GetCellText(0, 0));
    }

    [Theory]
    [InlineData("SELECT p.id, q.name FROM people p JOIN people q ON q.id = p.id", EditLock.MoreThanOneTable)]
    [InlineData("SELECT DISTINCT id, name FROM people", EditLock.Collapsed)]
    [InlineData("SELECT name FROM people", EditLock.KeyNotShown)]
    [InlineData("PRAGMA table_info(people)", EditLock.NotOneSelect)]
    public async Task AResultThatIsNotOneKeyedTablesRowsSaysWhy(string sql, EditLock expected)
    {
        var cancellationToken = TestContext.Current.CancellationToken;
        await using var database = await SqliteDatabase.CreateAsync();
        using var run = database.Editor.Run(sql, cancellationToken: cancellationToken);
        Assert.IsType<QueryOutcome.Completed>(await run.Completion);
        using var rows = run.GetResultSet(0) ?? throw new InvalidOperationException("The run held no set.");

        using var editor = await database.Session.OpenResultEditorAsync(sql, rows, cancellationToken);

        Assert.Equal(expected, editor.Lock);
        Assert.Null(editor.Table);
        Assert.Empty(editor.Columns);
    }
}
