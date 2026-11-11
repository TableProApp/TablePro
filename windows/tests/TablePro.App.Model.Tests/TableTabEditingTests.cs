using TablePro.DataGrid.Model;
using TablePro.Interop;

namespace TablePro.App.Model.Tests;

public sealed class TableTabEditingTests
{
    private readonly FakeSession _session = new() { TableRows = 3 };
    private readonly FakeTableView _view = new();
    private readonly FakeResults _results = new();
    private readonly TableTab _tab;

    public TableTabEditingTests()
    {
        _tab = new TableTab(_session, _view, _results, new TableName(null, "Artist"), () => new AppSettings());
        _view.Tab = _tab;
    }

    private FakeTableEditor Editor => _session.TableEditor;

    [Fact]
    public async Task APageReadMakesEditsForItsRowsAndAKeptEditStaysPending()
    {
        await _tab.RunAsync();

        var edits = Assert.IsType<TableEdits>(_tab.Edits);
        Assert.Equal(3, edits.DataRows);
        Assert.True(_tab.CanEdit);
        Assert.Null(_tab.StartEdit(1, 1, out var stored));
        Assert.Equal("r1c1", stored);
        Assert.Null(_tab.CommitEdit(1, 1, "Accept II"));
        Assert.True(_tab.HasUnsavedChanges);
        Assert.Null(_tab.StartEdit(1, 1, out var pending));
        Assert.Equal("Accept II", pending);
        Assert.Null(_tab.CommitEdit(1, 1, "r1c1"));
        Assert.False(_tab.HasUnsavedChanges);
        Assert.True(_view.EditsShown > 0);
    }

    [Fact]
    public async Task AnEditTheCoreRefusesIsNotKeptAndSaysWhy()
    {
        var failure = Errors.Of("edit.invalid_integer");
        Editor.Checker = (_, _, _) => failure;
        await _tab.RunAsync();

        var refusal = Assert.IsType<EditRefusal.Invalid>(_tab.CommitEdit(0, 1, "x"));

        Assert.Same(failure, refusal.Failure);
        Assert.False(_tab.HasUnsavedChanges);
    }

    [Fact]
    public async Task AValueWithNoTextToEditARowMarkedForDeleteAndACellPastThePageDoNotOpen()
    {
        Editor.Start = (_, column) =>
            column == 1 ? (EditStart)EditStart.Locked.Instance : new EditStart.Editable("1", IsNull: false);
        await _tab.RunAsync();

        Assert.IsType<EditRefusal.CellLocked>(_tab.StartEdit(0, 1, out _));
        Assert.Null(_tab.DeleteRows([2]));
        Assert.IsType<EditRefusal.RowDeleted>(_tab.StartEdit(2, 0, out _));
        Assert.IsType<EditRefusal.CellLocked>(_tab.StartEdit(9, 0, out _));
        Assert.IsType<EditRefusal.CellLocked>(_tab.CommitEdit(0, 1, "x"));
    }

    [Fact]
    public async Task AReadOnlyConnectionLocksEveryEditAndSaysWhy()
    {
        Editor.Lock = EditLock.ReadOnlyConnection;
        await _tab.RunAsync();

        Assert.True(_tab.AcceptsEdits);
        Assert.False(_tab.CanEdit);
        Assert.Equal(new EditRefusal.TableLocked(EditLock.ReadOnlyConnection), _tab.StartEdit(0, 1, out _));
        Assert.IsType<EditRefusal.TableLocked>(_tab.AddRow(out _));
        Assert.IsType<EditRefusal.TableLocked>(_tab.DeleteRows([0]));
        Assert.False(_tab.CanSetValue(0, 1, CellValueKind.Null));
        Assert.False(_tab.HasUnsavedChanges);
    }

    [Fact]
    public async Task ATableEditorThatCannotOpenLeavesThePageShownAndReadOnly()
    {
        _session.TableEditorFailure = Errors.Of("catalog.columns_unavailable");

        await _tab.RunAsync();

        Assert.Single(_session.Queries);
        Assert.Null(_tab.Edits);
        Assert.False(_tab.AcceptsEdits);
        Assert.IsType<EditRefusal.Busy>(_tab.StartEdit(0, 1, out _));
    }

    [Fact]
    public async Task TheTableEditorOpensWithThePageAndAgainOnRefresh()
    {
        await _tab.RunAsync();
        await _tab.FirstPageAsync();

        Assert.Equal(1, _session.TableEditorOpens);

        await _tab.RefreshAsync();

        Assert.Equal(2, _session.TableEditorOpens);
        Assert.Equal<bool>([false, true], _session.TableEditorRefreshes);
    }

    [Fact]
    public async Task SetValueOffersWhatTheColumnTakesAndDefaultInANewRowWhereTheServerFillsIt()
    {
        Editor.Columns =
        [
            Editor.Columns[0],
            Editor.Columns[1],
            new(
                "Country",
                Editable: true,
                EditableInNewRow: true,
                CellEdit.ServerDefault.Instance,
                Nullable: false,
                PrimaryKey: false,
                TakesEmpty: false,
                TakesDefault: true),
        ];
        await _tab.RunAsync();
        var edits = Assert.IsType<TableEdits>(_tab.Edits);

        Assert.False(_tab.CanSetValue(0, 0, CellValueKind.Null));
        Assert.True(_tab.CanSetValue(0, 1, CellValueKind.Null));
        Assert.True(_tab.CanSetValue(0, 1, CellValueKind.Empty));
        Assert.False(_tab.CanSetValue(0, 2, CellValueKind.Empty));
        Assert.False(_tab.CanSetValue(0, 1, CellValueKind.Default));
        Assert.True(_tab.CanSetValue(0, 2, CellValueKind.Default));
        Assert.Null(_tab.AddRow(out var row));
        Assert.False(_tab.CanSetValue(row, 0, CellValueKind.Default));
        Assert.False(_tab.CanSetValue(row, 1, CellValueKind.Default));
        Assert.True(_tab.CanSetValue(row, 2, CellValueKind.Default));
        Assert.Null(_tab.SetValue(0, 1, CellValueKind.Null));
        Assert.Null(_tab.SetValue(1, 1, CellValueKind.Empty));
        Assert.Null(_tab.SetValue(2, 2, CellValueKind.Default));
        Assert.IsType<EditRefusal.CellLocked>(_tab.SetValue(0, 0, CellValueKind.Null));

        Assert.Equal(CellEdit.Null.Instance, edits.GetCell(0, 1));
        Assert.Equal(new CellEdit.Text(string.Empty), edits.GetCell(1, 1));
        Assert.Equal(CellEdit.ServerDefault.Instance, edits.GetCell(2, 2));
    }

    [Fact]
    public async Task APageWhoseKeysCannotBeReadBackExactlyIsReadOnly()
    {
        Editor.PageLock = EditLock.KeyUnreadable;

        await _tab.RunAsync();

        Assert.Equal(EditLock.KeyUnreadable, _tab.Lock);
        Assert.False(_tab.CanEdit);
        Assert.Equal(new EditRefusal.TableLocked(EditLock.KeyUnreadable), _tab.StartEdit(0, 1, out _));
    }

    [Fact]
    public async Task AnOpenEditTheGridCannotKeepHoldsBackAReloadAndAClose()
    {
        await _tab.RunAsync();
        _view.CommitsOpenEdit = false;

        await _tab.RefreshAsync();

        Assert.Single(_session.Queries);
        Assert.False(await _tab.ConfirmCloseAsync(offerSave: true));
        Assert.Equal(0, _view.ClosesAsked);
    }

    [Fact]
    public async Task AddDuplicateDeleteAndRestoreChangeThePendingRows()
    {
        await _tab.RunAsync();
        var edits = Assert.IsType<TableEdits>(_tab.Edits);

        Assert.Null(_tab.AddRow(out var added));
        Assert.Equal(3, added);
        Assert.Equal(1, _tab.FirstColumnToFill);
        Assert.Null(_tab.DuplicateRows([1, 0], out var last));
        Assert.Equal(5, last);
        Assert.Equal(new CellEdit.Text("r0c1"), edits.GetCell(4, 1));
        Assert.Equal(CellEdit.ServerDefault.Instance, edits.GetCell(4, 0));
        Assert.Null(_tab.DeleteRows([0, added]));
        Assert.True(edits.IsDeleted(0));
        Assert.Equal(2, edits.AddedRows);
        Assert.Null(_tab.RestoreRows([0]));
        Assert.False(edits.IsDeleted(0));
    }

    [Fact]
    public async Task EveryReloadAsksWhileChangesArePendingAndANoKeepsThem()
    {
        await _tab.RunAsync();
        _tab.CommitEdit(0, 1, "changed");
        _view.DiscardsForReload = false;

        await _tab.RefreshAsync();
        await _tab.SortAsync(new GridSort(1, SortDirection.Ascending));
        await _tab.ResizeAsync(500);
        await _tab.FirstPageAsync();

        Assert.Equal<ReloadReason>(
            [ReloadReason.Refresh, ReloadReason.Sort, ReloadReason.PageSize, ReloadReason.Page],
            _view.ReloadsAsked);
        Assert.Single(_session.Queries);
        Assert.True(_tab.HasUnsavedChanges);
        Assert.False(await _tab.MayReloadAsync(ReloadReason.Refresh));

        _view.DiscardsForReload = true;
        await _tab.RefreshAsync();

        Assert.Equal(2, _session.Queries.Count);
        Assert.False(_tab.HasUnsavedChanges);
        Assert.NotNull(_tab.Edits);
    }

    [Fact]
    public async Task DiscardAsksFirstAndForgetsEveryChange()
    {
        await _tab.RunAsync();
        _tab.AddRow(out _);
        _view.Discards = false;

        await _tab.DiscardAsync();

        Assert.True(_tab.HasUnsavedChanges);

        _view.Discards = true;
        await _tab.DiscardAsync();

        Assert.False(_tab.HasUnsavedChanges);
        Assert.Single(_session.Queries);
    }

    [Fact]
    public async Task PreviewShowsThePlannedStatementsOrWhyThereAreNone()
    {
        await _tab.RunAsync();
        _tab.CommitEdit(0, 1, "changed");
        _tab.DeleteRows([1]);
        _tab.AddRow(out _);

        await _tab.PreviewAsync();

        var (statements, failure) = Assert.Single(_view.Previews);
        Assert.Null(failure);
        Assert.Equal<string>(["UPDATE", "DELETE", "INSERT"], statements.Select(statement => statement.Sql));

        Editor.PlanFailure = Errors.Of("build.no_insert_values");
        await _tab.PreviewAsync();

        Assert.Equal("build.no_insert_values", _view.Previews[^1].Failure?.Code);
        Assert.DoesNotContain(Editor.Saves, save => save.Runs > 0);
        Assert.True(_tab.HasUnsavedChanges);
    }

    [Fact]
    public async Task ASaveThatWritesClearsTheChangesAndReadsThePageAgainWithoutAsking()
    {
        await _tab.RunAsync();
        _tab.CommitEdit(0, 1, "changed");

        Assert.True(await _tab.SaveAsync());

        Assert.False(_tab.HasUnsavedChanges);
        Assert.Equal(2, _session.Queries.Count);
        Assert.Empty(_view.ReloadsAsked);
        Assert.Empty(_view.DeletesAsked);
        Assert.Empty(_view.SavesAsked);
        var save = Assert.Single(Editor.Saves);
        Assert.Equal(1, save.Runs);
        Assert.True(save.Confirmed);
        Assert.Equal(1, save.Disposals);
        Assert.Equal<string>(["saving", "saved"], _view.Shown);
        Assert.False(_tab.IsSaving);
    }

    [Fact]
    public async Task EveryDeleteIsAskedAboutAndANoSavesNothing()
    {
        await _tab.RunAsync();
        _tab.DeleteRows([0, 2]);
        _view.ConfirmsDelete = false;

        Assert.False(await _tab.SaveAsync());

        Assert.Equal(("Artist", 2), Assert.Single(_view.DeletesAsked));
        Assert.Equal(0, Assert.Single(Editor.Saves).Runs);
        Assert.True(_tab.HasUnsavedChanges);
    }

    [Fact]
    public async Task ConfirmWritesShowsTheStatementsAfterTheDeleteQuestionAndCancelSavesNothing()
    {
        Editor.Verdict = SaveGate.Confirm;
        await _tab.RunAsync();
        _tab.DeleteRows([1]);
        _view.ConfirmsSave = false;

        Assert.False(await _tab.SaveAsync());

        Assert.Single(_view.DeletesAsked);
        Assert.Equal("DELETE", Assert.Single(Assert.Single(_view.SavesAsked)).Sql);
        Assert.Equal(1, _view.SavesCancelled);
        Assert.Equal(0, Assert.Single(Editor.Saves).Runs);

        _view.ConfirmsSave = true;

        Assert.True(await _tab.SaveAsync());
        Assert.Equal(1, Editor.Saves[^1].Runs);
        Assert.True(Editor.Saves[^1].Confirmed);
    }

    [Fact]
    public async Task AReadOnlyLevelAtSaveTimeRefusesTheSave()
    {
        Editor.Verdict = SaveGate.Refuse;
        await _tab.RunAsync();
        _tab.CommitEdit(0, 1, "changed");

        Assert.False(await _tab.SaveAsync());

        Assert.Equal(new EditRefusal.TableLocked(EditLock.ReadOnlyConnection), Assert.Single(_view.Refusals));
        Assert.Equal(0, Assert.Single(Editor.Saves).Runs);
        Assert.True(_tab.HasUnsavedChanges);
    }

    [Fact]
    public async Task APlanWithNothingToWriteDropsTheChanges()
    {
        Editor.PlansNothing = true;
        await _tab.RunAsync();
        _tab.CommitEdit(0, 1, "1.0");

        Assert.True(await _tab.SaveAsync());

        Assert.False(_tab.HasUnsavedChanges);
        Assert.Equal(0, Assert.Single(Editor.Saves).Runs);
        Assert.Single(_session.Queries);
    }

    [Fact]
    public async Task ARolledBackSaveKeepsEveryChangeAndShowsTheRowItStoppedAt()
    {
        Editor.Outcome = () => new RowSaveOutcome.RolledBack(Errors.Of("driver.row_guard_failed"), 1);
        await _tab.RunAsync();
        _tab.DeleteRows([0]);
        _tab.CommitEdit(2, 1, "changed");

        Assert.False(await _tab.SaveAsync());

        var (failure, incomplete) = Assert.Single(_view.Failures);
        Assert.Equal("driver.row_guard_failed", failure.Code);
        Assert.False(incomplete);
        Assert.Equal(2, Assert.Single(_view.Focused));
        Assert.True(_tab.HasUnsavedChanges);
        Assert.True(_tab.CanSave);
        Assert.Single(_session.Queries);
    }

    [Fact]
    public async Task AnUnknownOutcomeKeepsTheChangesAndRefusesASaveUntilTheRowsAreReadAgain()
    {
        Editor.Outcome = () => new RowSaveOutcome.Unknown(Errors.Of("driver.commit_outcome_unknown"), 0);
        await _tab.RunAsync();
        _tab.CommitEdit(0, 1, "changed");

        Assert.False(await _tab.SaveAsync());

        Assert.True(Assert.Single(_view.Failures).Incomplete);
        Assert.Equal(0, Assert.Single(_view.Focused));
        Assert.True(_tab.HasUnsavedChanges);
        Assert.False(_tab.CanSave);
        Assert.False(await _tab.SaveAsync());
        Assert.IsType<EditRefusal.SaveBlocked>(Assert.Single(_view.Refusals));
        Assert.Single(Editor.Saves);

        await _tab.RefreshAsync();
        _tab.CommitEdit(0, 1, "again");

        Assert.True(_tab.CanSave);
    }

    [Fact]
    public async Task ASaveTheCoreRefusesToRunKeepsTheChanges()
    {
        Editor.Outcome = () => throw new TableProException(Errors.Of("edit.safe_mode_changed"));
        await _tab.RunAsync();
        _tab.CommitEdit(0, 1, "changed");

        Assert.False(await _tab.SaveAsync());

        Assert.Equal("edit.safe_mode_changed", Assert.Single(_view.Failures).Failure.Code);
        Assert.False(Assert.Single(_view.Failures).Incomplete);
        Assert.True(_tab.HasUnsavedChanges);
        Assert.True(_tab.CanSave);
        Assert.False(_tab.IsSaving);
    }

    [Fact]
    public async Task AnyOtherFailureOfARunningSaveIsTakenAsMaybeWrittenAndBlocksTheNext()
    {
        Editor.Outcome = () => throw new TableProException(Errors.Of("ffi.panicked"));
        await _tab.RunAsync();
        _tab.CommitEdit(0, 1, "changed");

        Assert.False(await _tab.SaveAsync());

        Assert.True(Assert.Single(_view.Failures).Incomplete);
        Assert.True(_tab.HasUnsavedChanges);
        Assert.False(_tab.CanSave);
    }

    [Fact]
    public async Task ADiscardingReloadClearsTheSaveBlockEvenWhenTheReloadFails()
    {
        Editor.Outcome = () => new RowSaveOutcome.Unknown(Errors.Of("driver.commit_outcome_unknown"), null);
        await _tab.RunAsync();
        _tab.CommitEdit(0, 1, "changed");
        Assert.False(await _tab.SaveAsync());
        _session.QueryFailure = Errors.Of("ffi.not_connected");

        await _tab.RefreshAsync();
        _tab.CommitEdit(0, 1, "again");

        Assert.Equal("error ffi.not_connected", _results.Shown[^1]);
        Assert.True(_tab.CanSave);
    }

    [Fact]
    public async Task AValueStillInTheOpenEditorCountsAsUnsavedAndSaveKeepsItFirst()
    {
        await _tab.RunAsync();
        _view.HasOpenEdit = true;
        _view.OnCommit = () => _tab.CommitEdit(0, 1, "typed");

        Assert.True(_tab.HasUnsavedChanges);
        Assert.True(_tab.CanSave);
        Assert.True(await _tab.SaveAsync());

        Assert.False(_view.HasOpenEdit);
        Assert.Equal(1, Assert.Single(Editor.Saves).Runs);
        Assert.IsType<RowEdit.Update>(Assert.Single(Assert.Single(Editor.Plans)));
    }

    [Fact]
    public async Task AnOpenEditorWhoseTextIsUnchangedClosesWithoutAQuestion()
    {
        await _tab.RunAsync();
        _view.HasOpenEdit = true;

        Assert.True(_tab.HasUnsavedChanges);
        Assert.True(await _tab.ConfirmCloseAsync(offerSave: true));

        Assert.Equal(0, _view.ClosesAsked);
    }

    [Fact]
    public async Task ACloseWhileASaveRunsWaitsForItAndAsksNothingOnceItSaved()
    {
        var saving = new Gate();
        Editor.Saving = saving;
        await _tab.RunAsync();
        _tab.CommitEdit(0, 1, "changed");

        var save = _tab.SaveAsync();
        await saving.Reached;
        var closing = _tab.ConfirmCloseAsync(offerSave: true);
        var waited = !closing.IsCompleted;
        saving.Open();

        Assert.True(await closing);
        Assert.True(await save);
        Assert.True(waited);
        Assert.Equal(0, _view.ClosesAsked);
    }

    [Fact]
    public async Task MakingTheConnectionReadOnlyOffersOnlyDontSaveAndCancel()
    {
        await _tab.RunAsync();
        _tab.CommitEdit(0, 1, "changed");
        _view.CloseAnswer = SaveBeforeClose.Save;

        Assert.False(await _tab.ConfirmCloseAsync(offerSave: false));

        Assert.False(_view.OffersSave);
        Assert.Empty(Editor.Plans);

        _view.CloseAnswer = SaveBeforeClose.DontSave;

        Assert.True(await _tab.ConfirmCloseAsync(offerSave: false));
    }

    [Fact]
    public async Task AnOpenEditTheGridCannotKeepStopsTheSave()
    {
        await _tab.RunAsync();
        _tab.CommitEdit(0, 1, "changed");
        _view.CommitsOpenEdit = false;

        Assert.False(await _tab.SaveAsync());

        Assert.Empty(Editor.Plans);
    }

    [Fact]
    public async Task ClosingDuringASaveWaitsForItAndReadsNothingAfter()
    {
        var saving = new Gate();
        Editor.Saving = saving;
        await _tab.RunAsync();
        _tab.CommitEdit(0, 1, "changed");

        var save = _tab.SaveAsync();
        await saving.Reached;
        var closing = _tab.CloseAsync();
        var waited = !closing.IsCompleted;
        saving.Open();

        Assert.True(await save);
        await closing;
        Assert.True(waited);
        Assert.Single(_session.Queries);
        Assert.Equal(1, Editor.Disposals);
        Assert.Equal(1, _session.Releases);
    }

    [Fact]
    public async Task ACloseAsksAboutPendingChangesAndClosesOnlyOnceTheyAreSavedOrLeft()
    {
        await _tab.RunAsync();

        Assert.True(await _tab.ConfirmCloseAsync(offerSave: true));
        Assert.Equal(0, _view.ClosesAsked);

        _tab.CommitEdit(0, 1, "changed");
        _view.CloseAnswer = SaveBeforeClose.Cancel;
        Assert.False(await _tab.ConfirmCloseAsync(offerSave: true));
        _view.CloseAnswer = SaveBeforeClose.DontSave;
        Assert.True(await _tab.ConfirmCloseAsync(offerSave: true));
        Assert.True(_tab.HasUnsavedChanges);

        _view.CloseAnswer = SaveBeforeClose.Save;
        Editor.Outcome = () => new RowSaveOutcome.RolledBack(Errors.Of("driver.rolled_back"), null);
        Assert.False(await _tab.ConfirmCloseAsync(offerSave: true));
        Editor.Outcome = () => new RowSaveOutcome.Saved(1);
        Assert.True(await _tab.ConfirmCloseAsync(offerSave: true));

        Assert.False(_tab.HasUnsavedChanges);
        Assert.Equal(4, _view.ClosesAsked);
        Assert.Single(_session.Queries);
    }
}
