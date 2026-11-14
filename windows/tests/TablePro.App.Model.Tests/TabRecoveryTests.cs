using System.Globalization;
using TablePro.DataGrid.Model;
using TablePro.Interop;

namespace TablePro.App.Model.Tests;

// The fake page's key cells read "r{row}c0", so a saved key names a row by that text.
public sealed class TabRecoveryTests
{
    private readonly FakeSession _session = new() { TableRows = 3 };
    private readonly FakeTableView _view = new();
    private readonly FakeResults _results = new();

    private FakeTableEditor Editor => _session.TableEditor;

    [Fact]
    public async Task ARestoredTabPutsItsChangesBackOnceItsPageIsReadAndKeepsTheRestWaiting()
    {
        var gone = new SavedRowEdit { Key = Key("r9c0"), Cells = Name("gone") };
        var saved = new SavedEdits
        {
            Rows =
            [
                new SavedRowEdit { Key = Key("r2c0"), Cells = Name("Grace Hopper") },
                new SavedRowEdit { Key = Key("r0c0"), Deleted = true },
                gone,
                new SavedRowEdit { Cells = Name("Ada") },
            ],
        };
        var tab = Restored(saved);

        // Until a page shows, the changes wait and the session keeps them as they came.
        Assert.Null(tab.Edits);
        Assert.Same(saved, tab.Snapshot().Edits);
        await tab.ShowAsync();

        var edits = Assert.IsType<TableEdits>(tab.Edits);
        Assert.Equal(new CellEdit.Text("Grace Hopper"), edits.GetCell(2, 1));
        Assert.True(edits.IsDeleted(0));
        Assert.Equal(new CellEdit.Text("Ada"), edits.GetCell(3, 1));
        Assert.Equal([(3, 1, false)], _view.Recovered);
        Assert.Equal(1, tab.WaitingChanges);
        Assert.True(tab.HasUnsavedChanges);

        // Nobody answered for the waiting one, so even a close's last write keeps it.
        Assert.Same(gone, Assert.Single(tab.Snapshot().Edits!.Rows));
        var kept = tab.WithPendingWork(tab.Snapshot()).Edits!;
        Assert.Equal<string?>(["r9c0", "r2c0", "r0c0", null], kept.Rows.Select(row => row.Key?["ArtistId"].Text));
    }

    [Fact]
    public async Task ATabWhosePageMovedFindsItsRowsByKey()
    {
        // The page reads the rows the other way round: its key cells hold 2, 1 and 0.
        Editor.Values = (row, column) => column == 0
            ? new StoredValue(ValueKind.Integer, (2 - row).ToString(CultureInfo.InvariantCulture))
            : new StoredValue(ValueKind.Text, FakeTableEditor.Stored(row, column));
        var tab = Restored(new SavedEdits { Rows = [new SavedRowEdit { Key = Key("0"), Cells = Name("moved") }] });

        await tab.ShowAsync();

        Assert.Equal(new CellEdit.Text("moved"), tab.Edits!.GetCell(2, 1));
        Assert.Equal([(1, 0, false)], _view.Recovered);
        Assert.Equal(0, tab.WaitingChanges);
    }

    [Fact]
    public async Task AChangeWaitingForItsRowSurvivesTheSessionFileAndComesBackOnTheLaterPageThatHoldsIt()
    {
        var path = Path.Combine(Directory.CreateTempSubdirectory("tablepro-waiting-").FullName, "session.json");
        _session.TableRows = 6;
        var first = Restored(new SavedEdits
        {
            Rows =
            [
                new SavedRowEdit { Key = Key("later"), Cells = Name("waited") },
                new SavedRowEdit { Key = Key("r1c0"), Cells = Name("here") },
            ],
        }, pageSize: 3);
        await first.ShowAsync();
        new SessionStore(path).Save(new SessionState
        {
            Connections =
            [
                new SessionConnection { FilePath = "chinook.sqlite", Tabs = [first.WithPendingWork(first.Snapshot())] },
            ],
        });
        _view.Recovered.Clear();

        var reloaded = Assert.Single(Assert.Single(new SessionStore(path).Load().Connections).Tabs);
        var tab = Restored(reloaded.Edits, pageSize: 3);
        await tab.ShowAsync();
        Assert.Equal(new CellEdit.Text("here"), tab.Edits!.GetCell(1, 1));
        Assert.Equal(1, tab.WaitingChanges);

        // The next page holds the row, as its third; going there discards the change pending on this one.
        Editor.Values = KeyAt(2, "later");
        await tab.NextPageAsync();
        Assert.Equal(3, tab.Page.Offset);

        Assert.Equal(new CellEdit.Text("waited"), tab.Edits!.GetCell(2, 1));
        Assert.Null(tab.Edits.GetCell(1, 1));
        Assert.Equal([(1, 1, false), (1, 0, false)], _view.Recovered);
        Assert.Equal(0, tab.WaitingChanges);
        Assert.Null(tab.Snapshot().Edits);
        Directory.Delete(Path.GetDirectoryName(path)!, recursive: true);
    }

    [Fact]
    public async Task ALockKeepsEveryRecoveredChangeForTheNextPage()
    {
        Editor.Lock = EditLock.ReadOnlyConnection;
        var saved = new SavedEdits
        {
            Rows =
            [
                new SavedRowEdit { Key = Key("r1c0"), Cells = Name("x") },
                new SavedRowEdit { Cells = Name("y") },
            ],
        };
        var tab = Restored(saved);

        await tab.ShowAsync();

        Assert.False(tab.HasUnsavedChanges);
        Assert.Equal([(0, 2, false)], _view.Recovered);
        Assert.Same(saved, tab.Snapshot().Edits);

        Editor.Lock = null;
        await tab.RunAsync();

        Assert.Equal(new CellEdit.Text("x"), tab.Edits!.GetCell(1, 1));
        Assert.Equal(new CellEdit.Text("y"), tab.Edits.GetCell(3, 1));
        Assert.Equal((2, 0, false), _view.Recovered[^1]);
        Assert.Null(tab.Snapshot().Edits);
    }

    [Fact]
    public async Task DiscardDropsOnlyTheWaitingChanges()
    {
        var tab = Restored(new SavedEdits
        {
            Rows =
            [
                new SavedRowEdit { Key = Key("r1c0"), Cells = Name("here") },
                new SavedRowEdit { Key = Key("elsewhere"), Cells = Name("waited") },
            ],
        });
        await tab.ShowAsync();
        var changed = 0;
        tab.StateChanged += (_, _) => changed++;

        tab.DiscardWaiting();

        Assert.Equal(0, tab.WaitingChanges);
        Assert.Equal((0, 0, false), _view.Recovered[^1]);
        Assert.True(changed > 0);
        Assert.Null(tab.Snapshot().Edits);
        Assert.True(tab.HasUnsavedChanges);
        Assert.Equal("r1c0", Assert.Single(tab.WithPendingWork(tab.Snapshot()).Edits!.Rows).Key!["ArtistId"].Text);

        // Nothing waits any more, so a later page tries nothing.
        await tab.RunAsync();
        Assert.Equal((0, 0, false), _view.Recovered[^1]);
    }

    [Fact]
    public async Task ASaveWhoseOutcomeIsUnknownComesBackBlockedUntilTheTableIsReadAgain()
    {
        var path = Path.Combine(Directory.CreateTempSubdirectory("tablepro-unknown-").FullName, "session.json");
        var first = Restored(null);
        await first.RunAsync();
        Assert.Null(first.CommitEdit(1, 1, "maybe"));
        Editor.Outcome = () => new RowSaveOutcome.Unknown(Errors.Of("driver.connection_lost"), null);
        Assert.False(await first.SaveAsync());
        Assert.False(first.CanSave);
        var written = first.WithPendingWork(first.Snapshot());
        Assert.True(Assert.Single(written.Edits!.Rows).Uncertain);
        new SessionStore(path).Save(new SessionState
        {
            Connections = [new SessionConnection { FilePath = "chinook.sqlite", Tabs = [written] }],
        });

        Editor.Outcome = () => new RowSaveOutcome.Saved(1);
        var plans = Editor.Plans.Count;
        var tab = Restored(Assert.Single(Assert.Single(new SessionStore(path).Load().Connections).Tabs).Edits);
        await tab.ShowAsync();

        Assert.Equal(new CellEdit.Text("maybe"), tab.Edits!.GetCell(1, 1));
        Assert.Equal((1, 0, true), _view.Recovered[^1]);
        Assert.True(tab.HasUnsavedChanges);
        Assert.False(tab.CanSave);
        Assert.False(await tab.SaveAsync());
        Assert.IsType<EditRefusal.SaveBlocked>(_view.Refusals[^1]);
        Assert.Equal(plans, Editor.Plans.Count);
        // Written blocked again, so a second end keeps it so.
        Assert.True(Assert.Single(tab.WithPendingWork(tab.Snapshot()).Edits!.Rows).Uncertain);

        // The way out after an unknown outcome: a reload, which asks to discard and reads the rows again.
        await tab.RunAsync();

        Assert.Contains(ReloadReason.Refresh, _view.ReloadsAsked);
        Assert.Equal((0, 0, false), _view.Recovered[^1]);
        Assert.False(tab.HasUnsavedChanges);
        Assert.Null(tab.CommitEdit(1, 1, "sure"));
        Assert.True(tab.CanSave);
        Directory.Delete(Path.GetDirectoryName(path)!, recursive: true);
    }

    [Fact]
    public async Task DiscardingTheChangesOfAnUncertainSaveLiftsTheBlock()
    {
        var tab = Restored(new SavedEdits
        {
            Rows = [new SavedRowEdit { Key = Key("r1c0"), Cells = Name("maybe"), Uncertain = true }],
        });
        await tab.ShowAsync();
        Assert.False(tab.CanSave);

        await tab.DiscardAsync();

        Assert.False(tab.HasUnsavedChanges);
        Assert.Equal((0, 0, false), _view.Recovered[^1]);
        Assert.Null(tab.CommitEdit(1, 1, "sure"));
        Assert.True(tab.CanSave);
    }

    [Fact]
    public async Task AChangeWaitingFromAnUncertainSaveBlocksOnlyOnceItGoesBack()
    {
        var tab = Restored(new SavedEdits
        {
            Rows = [new SavedRowEdit { Key = Key("later"), Cells = Name("maybe"), Uncertain = true }],
        });
        await tab.ShowAsync();
        Assert.Equal((0, 1, false), _view.Recovered[^1]);
        Assert.Null(tab.CommitEdit(1, 1, "sure"));
        Assert.True(tab.CanSave);
        Assert.Equal<bool>(
            [true, false],
            tab.WithPendingWork(tab.Snapshot()).Edits!.Rows.Select(row => row.Uncertain));

        Editor.Values = KeyAt(2, "later");
        await tab.RunAsync();

        Assert.Equal(new CellEdit.Text("maybe"), tab.Edits!.GetCell(2, 1));
        Assert.Equal((1, 0, true), _view.Recovered[^1]);
        Assert.False(tab.CanSave);
    }

    [Fact]
    public async Task TheSessionFileHoldsTheEditsAsUncertainBeforeASaveSendsAnything()
    {
        var tab = Restored(null);
        await tab.RunAsync();
        Assert.Null(tab.CommitEdit(1, 1, "x"));
        Assert.Null(tab.AddRow(out _));
        SavedEdits? written = null;
        var statementsRun = -1;
        _view.OnSessionWrite = () =>
        {
            written = tab.WithPendingWork(tab.Snapshot()).Edits;
            statementsRun = Editor.Saves.Sum(save => save.Runs);
        };

        Assert.True(await tab.SaveAsync());

        Assert.Equal(1, _view.SessionWrites);
        Assert.Equal(0, statementsRun);
        Assert.Equal(2, written!.Rows.Count);
        Assert.All(written.Rows, row => Assert.True(row.Uncertain));
        Assert.Equal(1, Assert.Single(Editor.Saves).Runs);
    }

    [Fact]
    public async Task NoSessionWriteComesBeforeASaveThatSendsNothing()
    {
        var tab = Restored(null);
        await tab.RunAsync();
        Assert.Null(tab.CommitEdit(1, 1, "x"));
        _view.ConfirmsSave = false;
        Editor.Verdict = SaveGate.Confirm;

        Assert.False(await tab.SaveAsync());
        Editor.PlansNothing = true;
        _view.ConfirmsSave = true;
        Assert.True(await tab.SaveAsync());

        Assert.Equal(0, _view.SessionWrites);
    }

    [Fact]
    public async Task ASaveRunningAsTheFileIsWrittenIsKeptAsUncertain()
    {
        var tab = Restored(null);
        await tab.RunAsync();
        Assert.Null(tab.CommitEdit(1, 1, "x"));
        Assert.False(Assert.Single(tab.WithPendingWork(tab.Snapshot()).Edits!.Rows).Uncertain);
        var saving = new Gate();
        Editor.Saving = saving;

        var save = tab.SaveAsync();
        await saving.Reached;
        var written = tab.WithPendingWork(tab.Snapshot());
        saving.Open();
        Assert.True(await save);

        Assert.True(Assert.Single(written.Edits!.Rows).Uncertain);
    }

    [Fact]
    public async Task TheOpenEditorsTextIsKeptAsIfTypedWithoutKeepingItInTheGrid()
    {
        var tab = Restored(null);
        await tab.RunAsync();
        _view.HasOpenEdit = true;
        _view.OpenDraft = new CellDraft(1, 1, "typing");

        // With nothing else pending, the draft alone is kept, by its row's key.
        var alone = Assert.Single(tab.WithPendingWork(tab.Snapshot()).Edits!.Rows);
        Assert.Equal("r1c0", alone.Key!["ArtistId"].Text);
        Assert.Equal(new SavedCell { Kind = "Text", Text = "typing" }, alone.Cells["Name"]);
        Assert.Null(tab.Edits!.GetCell(1, 1));

        // A row already edited takes the draft over its own cell, as the row's latest change.
        _view.OpenDraft = null;
        Assert.Null(tab.CommitEdit(1, 1, "kept"));
        Assert.Null(tab.CommitEdit(0, 1, "other"));
        _view.OpenDraft = new CellDraft(1, 1, "retyped");
        var kept = tab.WithPendingWork(tab.Snapshot()).Edits!;
        Assert.Equal<string?>(["r0c0", "r1c0"], kept.Rows.Select(row => row.Key?["ArtistId"].Text));
        Assert.Equal("retyped", kept.Rows[1].Cells["Name"].Text);
        Assert.Equal(new CellEdit.Text("kept"), tab.Edits.GetCell(1, 1));

        // A new row's draft lands in the row's own cells.
        Assert.Null(tab.AddRow(out var added));
        _view.OpenDraft = new CellDraft(added, 1, "new");
        var inserted = tab.WithPendingWork(tab.Snapshot()).Edits!.Rows[^1];
        Assert.Null(inserted.Key);
        Assert.Equal("new", inserted.Cells["Name"].Text);

        // A relaunch puts the draft back as a pending edit.
        _view.OpenDraft = null;
        _view.HasOpenEdit = false;
        var again = Restored(new SavedEdits { Rows = [alone] });
        await again.ShowAsync();
        Assert.Equal(new CellEdit.Text("typing"), again.Edits!.GetCell(1, 1));
    }

    [Fact]
    public async Task APageThatCouldNotBeReadKeepsTheChangesForTheNextOne()
    {
        _session.QueryFailure = Errors.Of("driver.connection_lost");
        var saved = new SavedEdits { Rows = [new SavedRowEdit { Key = Key("r1c0"), Cells = Name("x") }] };
        var tab = Restored(saved);

        await tab.ShowAsync();
        Assert.Empty(_view.Recovered);
        Assert.Same(saved, tab.WithPendingWork(tab.Snapshot()).Edits);

        _session.QueryFailure = null;
        await tab.RunAsync();
        Assert.Equal(new CellEdit.Text("x"), tab.Edits!.GetCell(1, 1));
        Assert.Equal([(1, 0, false)], _view.Recovered);
    }

    [Fact]
    public async Task OnlyTheSessionsOwnWritesKeepATablesPendingChanges()
    {
        var tab = Restored(null);
        await tab.RunAsync();
        Assert.Null(tab.WithPendingWork(tab.Snapshot()).Edits);

        Assert.Null(tab.CommitEdit(1, 1, "kept"));

        Assert.Null(tab.Snapshot().Edits);
        var kept = Assert.Single(tab.WithPendingWork(tab.Snapshot()).Edits!.Rows);
        Assert.Equal("r1c0", kept.Key!["ArtistId"].Text);
        Assert.Equal(new SavedCell { Kind = "Text", Text = "kept" }, kept.Cells["Name"]);
    }

    [Fact]
    public async Task OnlyTheSessionsOwnWritesSayAQueryTabHeldATransaction()
    {
        var tab = new QueryTab(
            "Query 1", _session, new FakeQueryView(), _results, DataModel.Relational, () => new AppSettings());
        Assert.False(tab.WithPendingWork(tab.Snapshot()).HeldTransaction);

        _session.Script = _ => FakeRun.Rows(0, TransactionState.InTransaction);
        await tab.RunAsync();

        Assert.False(tab.Snapshot().HeldTransaction);
        Assert.True(tab.WithPendingWork(tab.Snapshot()).HeldTransaction);
        Assert.True(tab.WithPendingWork(tab.Snapshot()).HasRecoveredWork);
    }

    private TableTab Restored(SavedEdits? edits, int? pageSize = null)
    {
        var tab = new TableTab(
            _session,
            _view,
            _results,
            new TableName(null, "Artist"),
            ObjectKind.Table,
            () => new AppSettings(),
            new SessionTab
            {
                Kind = TabKind.Table,
                Title = "Artist",
                Table = "Artist",
                PageSize = pageSize,
                Edits = edits,
            });
        _view.Tab = tab;
        return tab;
    }

    private static Dictionary<string, SavedKeyPart> Key(string id) =>
        new() { ["ArtistId"] = new SavedKeyPart { Kind = "Integer", Text = id } };

    // The fake page with this key at that row, as when the row moved there.
    private static Func<long, int, StoredValue> KeyAt(long at, string id) => (row, column) =>
        new StoredValue(
            column == 0 ? ValueKind.Integer : ValueKind.Text,
            column == 0 && row == at ? id : FakeTableEditor.Stored(row, column));

    private static Dictionary<string, SavedCell> Name(string name) =>
        new() { ["Name"] = new SavedCell { Kind = "Text", Text = name } };
}
