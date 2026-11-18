using TablePro.DataGrid.Model;
using TablePro.Interop;

namespace TablePro.App.Model.Tests;

public sealed class QueryTabEditingTests
{
    private readonly FakeSession _session = new() { Script = _ => FakeRun.Rows(3) };
    private readonly FakeQueryView _view = new();
    private readonly FakeResults _results = new();
    private readonly FakeResultEditView _edits = new();
    private readonly FakeHistoryRecorder _history = new();
    private readonly QueryTab _tab;

    public QueryTabEditingTests()
    {
        _tab = Tab(null);
    }

    private FakeTableEditor Editor => _session.ResultEditor;

    [Fact]
    public async Task AnEditedResultSavesAndItsStatementRunsAgainOutsideTheHistory()
    {
        await _tab.RunAsync();

        Assert.True(_tab.CanEditResult);
        Assert.Equal<string>(["select * from Artist"], _session.ResultEditorOpens);
        Assert.Null(_tab.StartEdit(1, 1, out var stored));
        Assert.Equal("r1c1", stored);
        Assert.Null(_tab.CommitEdit(1, 1, "Accept II"));
        Assert.True(_tab.HasUnsavedChanges);
        Assert.True(_tab.CanSaveRows);

        Assert.True(await _tab.SaveRowsAsync());

        var save = Assert.Single(Editor.Saves);
        Assert.Equal(1, save.Runs);
        Assert.True(save.Confirmed);
        Assert.IsType<RowEdit.Update>(Assert.Single(Assert.Single(Editor.Plans)));
        Assert.Equal<string>(["select * from Artist", "select * from Artist"], Assert.Single(_session.Editors).Runs);
        Assert.Equal(2, _session.ResultEditorOpens.Count);
        Assert.Single(_history.Runs);
        Assert.Equal<string>(["saving", "saved"], _edits.Shown);
        Assert.False(_tab.HasUnsavedChanges);
        Assert.True(_tab.CanEditResult);
    }

    [Fact]
    public async Task ARunWithSeveralResultsIsRefusedBeforeTheCoreIsAsked()
    {
        _session.Script = _ => FakeRun.Script();

        await _tab.RunAsync();

        Assert.True(_tab.ResultAcceptsEdits);
        Assert.False(_tab.CanEditResult);
        Assert.False(_tab.EditsResult);
        Assert.Equal(new EditRefusal.ResultBlocked(ResultEditBlock.SeveralResults), _tab.StartEdit(0, 1, out _));
        Assert.Equal(new EditRefusal.ResultBlocked(ResultEditBlock.SeveralResults), _tab.AddRow(out _));
        Assert.Empty(_session.ResultEditorOpens);
    }

    [Theory]
    [InlineData(TransactionState.InTransaction, ResultEditBlock.OpenTransaction)]
    [InlineData(TransactionState.Failed, ResultEditBlock.OpenTransaction)]
    [InlineData(TransactionState.Unknown, ResultEditBlock.UnknownTransaction)]
    public async Task ARunThatLeavesATransactionOpenOrUnsaidIsRefused(TransactionState state, ResultEditBlock block)
    {
        _session.Script = _ => FakeRun.Rows(3, state);

        await _tab.RunAsync();

        Assert.Equal(new EditRefusal.ResultBlocked(block), _tab.StartEdit(0, 1, out _));
        Assert.Empty(_session.ResultEditorOpens);
    }

    [Fact]
    public async Task ATabInAnotherDatabaseThanTheConnectionsIsRefused()
    {
        _session.Database = "app";
        var tab = Tab("shop");

        await tab.RunAsync();

        Assert.Equal(new EditRefusal.ResultBlocked(ResultEditBlock.OtherDatabase), tab.StartEdit(0, 1, out _));
        Assert.Empty(_session.ResultEditorOpens);
    }

    [Fact]
    public async Task ATypedUseThatMovedTheEditorIsRefused()
    {
        _session.Database = "app";
        await _tab.RunAsync();
        Assert.True(_tab.CanEditResult);
        var editor = Assert.Single(_session.Editors);
        editor.Database = "shop";

        await _tab.RunAsync();

        Assert.Equal(new EditRefusal.ResultBlocked(ResultEditBlock.OtherDatabase), _tab.StartEdit(0, 1, out _));
        Assert.Single(_session.ResultEditorOpens);
    }

    [Fact]
    public async Task CommitRunsNoStatementWhoseRowsCouldEdit()
    {
        _session.Script = _ => FakeRun.Rows(3, TransactionState.InTransaction);
        await _tab.RunAsync();
        _session.Script = _ => FakeRun.Rows(3);

        await _tab.CommitAsync();

        Assert.Equal(new EditRefusal.ResultBlocked(ResultEditBlock.RunAgain), _tab.StartEdit(0, 1, out _));
        Assert.Empty(_session.ResultEditorOpens);
    }

    [Fact]
    public async Task ALockFromTheCoreIsTheRefusal()
    {
        Editor.Lock = EditLock.Collapsed;
        Editor.PageLock = EditLock.Collapsed;

        await _tab.RunAsync();

        Assert.Equal(new EditRefusal.TableLocked(EditLock.Collapsed), _tab.StartEdit(0, 1, out _));
        Assert.Equal(new EditRefusal.TableLocked(EditLock.Collapsed), _tab.DeleteRows([0]));
        Assert.False(_tab.CanEditResult);
        Assert.False(_tab.EditsResult);
        Assert.Equal<string>(["select * from Artist"], _session.ResultEditorOpens);
    }

    [Fact]
    public async Task AResultWhoseTableCannotBeReadIsRefused()
    {
        _session.ResultEditorFailure = Errors.Of("catalog.columns_unavailable");

        await _tab.RunAsync();

        Assert.Equal(new EditRefusal.ResultBlocked(ResultEditBlock.ColumnsUnread), _tab.StartEdit(0, 1, out _));
        Assert.Null(_tab.ResultEdits);
    }

    [Fact]
    public async Task ARunASortOrADatabaseSwitchAsksFirstAndANoKeepsTheEdits()
    {
        _session.Sorted = (sql, columns, column, _) => $"{sql} order by {columns[column]}";
        await _tab.RunAsync();
        _tab.CommitEdit(0, 1, "changed");
        _edits.DiscardsForReplace = false;

        await _tab.RunAsync();
        await _tab.SortAsync(new GridSort(1, SortDirection.Ascending));
        await _tab.PickDatabaseAsync("shop");

        var editor = Assert.Single(_session.Editors);
        Assert.Equal<ResultReplacement>(
            [ResultReplacement.Run, ResultReplacement.Sort, ResultReplacement.Database],
            _edits.ReplacesAsked);
        Assert.Single(editor.Runs);
        Assert.Empty(editor.Databases);
        Assert.Equal(GridSort.None, _results.Sort);
        Assert.True(_tab.HasUnsavedChanges);
        Assert.True(_tab.CanSaveRows);

        _edits.DiscardsForReplace = true;
        await _tab.RunAsync();

        Assert.Equal(2, editor.Runs.Count);
        Assert.False(_tab.HasUnsavedChanges);
        Assert.True(_tab.CanEditResult);
    }

    [Fact]
    public async Task AnUnknownOutcomeBlocksSaveUntilDiscardWhichRunsTheStatementAgain()
    {
        Editor.Outcome = () => new RowSaveOutcome.Unknown(Errors.Of("driver.commit_outcome_unknown"), 0);
        await _tab.RunAsync();
        _tab.CommitEdit(0, 1, "changed");

        Assert.False(await _tab.SaveRowsAsync());

        Assert.True(Assert.Single(_edits.Failures).Incomplete);
        Assert.Equal(0, Assert.Single(_edits.Focused));
        Assert.True(_tab.HasUnsavedChanges);
        Assert.False(_tab.CanSaveRows);
        Assert.False(await _tab.SaveRowsAsync());
        Assert.IsType<EditRefusal.SaveBlocked>(Assert.Single(_edits.Refusals));
        Assert.Single(Editor.Saves);
        var editor = Assert.Single(_session.Editors);
        Assert.Single(editor.Runs);

        await _tab.DiscardRowsAsync();

        Assert.Equal(2, editor.Runs.Count);
        Assert.False(_tab.HasUnsavedChanges);
        Assert.Null(_tab.CommitEdit(0, 1, "again"));
        Assert.True(_tab.CanSaveRows);
    }

    [Fact]
    public async Task DeletesAreAskedAboutAndConfirmWritesShowsTheStatementsFirst()
    {
        Editor.Verdict = SaveGate.Confirm;
        await _tab.RunAsync();
        _tab.DeleteRows([1, 2]);
        _edits.ConfirmsSave = false;

        Assert.False(await _tab.SaveRowsAsync());

        Assert.Equal(2, Assert.Single(_edits.DeletesAsked));
        Assert.Equal<string>(["DELETE", "DELETE"], Assert.Single(_edits.SavesAsked).Select(statement => statement.Sql));
        Assert.Contains("save cancelled", _edits.Shown);
        Assert.Equal(0, Assert.Single(Editor.Saves).Runs);
        Assert.True(_tab.HasUnsavedChanges);
    }

    [Fact]
    public async Task ACloseAsksAboutPendingRowsAndSavesThenReadsThem()
    {
        await _tab.RunAsync();

        Assert.True(await _tab.ConfirmCloseAsync(offerSave: true));
        Assert.Equal(0, _edits.ClosesAsked);

        _tab.CommitEdit(0, 1, "changed");
        _edits.CloseAnswer = SaveBeforeClose.Cancel;
        Assert.False(await _tab.ConfirmCloseAsync(offerSave: true));
        _edits.CloseAnswer = SaveBeforeClose.DontSave;
        Assert.True(await _tab.ConfirmCloseAsync(offerSave: false));
        Assert.False(_edits.OffersSave);
        Assert.True(_tab.HasUnsavedChanges);

        _edits.CloseAnswer = SaveBeforeClose.Save;
        Assert.True(await _tab.ConfirmCloseAsync(offerSave: true));

        // Another tab's Cancel can keep this one open, so the rows show what the save wrote.
        Assert.True(_edits.OffersSave);
        Assert.Equal(1, Assert.Single(Editor.Saves).Runs);
        Assert.Equal(2, Assert.Single(_session.Editors).Runs.Count);
        Assert.False(_tab.HasUnsavedChanges);
        Assert.Equal(3, _edits.ClosesAsked);
    }

    [Fact]
    public async Task AHeldSortTellsTheViewTheRowsTakeEditsAgainOnceItEnds()
    {
        _session.Sorted = (_, _, _, _) => null;
        await _tab.RunAsync();
        var shown = _edits.EditsShown;

        await _tab.SortAsync(new GridSort(1, SortDirection.Ascending));

        Assert.True(_edits.EditsShown > shown);
        Assert.True(_tab.ResultAcceptsEdits);
    }

    [Fact]
    public async Task AHeldSortAfterAnUnknownOutcomeKeepsSaveBlocked()
    {
        Editor.Outcome = () => new RowSaveOutcome.Unknown(Errors.Of("driver.commit_outcome_unknown"), 0);
        await _tab.RunAsync();
        _tab.CommitEdit(0, 1, "changed");
        Assert.False(await _tab.SaveRowsAsync());

        await _tab.SortAsync(new GridSort(1, SortDirection.Ascending));
        Assert.Null(_tab.CommitEdit(0, 1, "again"));

        Assert.False(_tab.CanSaveRows);
        Assert.False(await _tab.SaveRowsAsync());
        Assert.IsType<EditRefusal.SaveBlocked>(Assert.Single(_edits.Refusals));
        Assert.Single(Editor.Saves);
    }

    [Fact]
    public async Task ASaveReadsTheRowsAgainAndSortsThemAsTheyWereShown()
    {
        await _tab.RunAsync();
        await _tab.SortAsync(new GridSort(1, SortDirection.Descending));
        _tab.CommitEdit(0, 1, "changed");

        Assert.True(await _tab.SaveRowsAsync());

        Assert.Equal(2, Assert.Single(_session.Editors).Runs.Count);
        Assert.Equal(2, _results.Shown.Count(shown => shown == "sort held"));
        Assert.Equal(new GridSort(1, SortDirection.Descending), _results.Sort);
    }

    [Fact]
    public async Task RowsSavedForACloseTheFileThenKeepsOpenAreReadAgain()
    {
        var directory = Directory.CreateTempSubdirectory("tablepro-result-close-").FullName;
        try
        {
            var path = Path.Combine(directory, "report.sql");
            File.WriteAllText(path, "select * from Artist");
            var read = SqlFile.Read(path);
            _view.WholeText = read.Text;
            var files = new NoPickFiles();
            var tab = new QueryTab(
                "report.sql",
                _session,
                _view,
                _results,
                DataModel.Relational,
                () => new AppSettings(),
                _history,
                files: files,
                filePath: path,
                onDisk: read,
                resultEdits: _edits);
            await tab.RunAsync();
            tab.CommitEdit(0, 1, "changed");
            _view.WholeText = "select * from Artist where 1 = 1";
            tab.TextEdited();
            File.Delete(path);

            Assert.False(await tab.ConfirmCloseAsync(offerSave: true));

            Assert.Equal(1, Assert.Single(Editor.Saves).Runs);
            Assert.Equal(2, Assert.Single(_session.Editors).Runs.Count);
            Assert.False(tab.HasPendingRows);
        }
        finally
        {
            Directory.Delete(directory, recursive: true);
        }
    }

    private QueryTab Tab(string? database) => new(
        "Query 1",
        _session,
        _view,
        _results,
        DataModel.Relational,
        () => new AppSettings(),
        _history,
        database,
        resultEdits: _edits);

    // The file is gone and Save As is dismissed, so its save fails.
    private sealed class NoPickFiles : IQueryFileView
    {
        public void ReplaceText(string text)
        {
        }

        public Task<string?> PickSavePathAsync(string suggestedName, string? folder) => Task.FromResult<string?>(null);

        public Task<SaveBeforeClose> AskSaveBeforeCloseAsync(string tab, bool offerSave) =>
            Task.FromResult(SaveBeforeClose.Save);

        public Task<SaveOverChange> AskSaveOverChangeAsync(string path) => Task.FromResult(SaveOverChange.Cancel);

        public void ShowDiskChange(DiskChange change)
        {
        }

        public Task ShowSaveFailedAsync(string path, Exception failure) => Task.CompletedTask;

        public Task ShowReloadFailedAsync(string path, Exception failure) => Task.CompletedTask;
    }
}
