using TablePro.DataGrid.Model;
using TablePro.Interop;

namespace TablePro.App.Model.Tests;

public sealed class QueryTabTests
{
    private readonly FakeSession _session = new();
    private readonly FakeQueryView _view = new();
    private readonly FakeResults _results = new();
    private readonly QueryTab _tab;

    public QueryTabTests()
    {
        _tab = new QueryTab("Query 1", _session, _view, _results, DataModel.Relational, () => new AppSettings());
    }

    [Fact]
    public async Task ATabClosedWhileItsEditorOpensOpensNoneAndLetsItsSessionGoOnce()
    {
        var opening = new Gate();
        _session.Opening = opening;

        var running = _tab.RunAsync();
        await opening.Reached;
        await _tab.CloseAsync();
        await running;

        Assert.Empty(_session.Editors);
        Assert.Equal(1, _session.Releases);
        Assert.Equal<string>(["clear"], _results.Shown);
        Assert.Equal<string>(["running", "idle", "editor closed"], _view.Shown);
    }

    [Fact]
    public async Task AnEditorThatOpensAsTheTabClosesIsDisposedOnceAndRunsNothing()
    {
        var opening = new Gate(honorsCancel: false);
        _session.Opening = opening;

        var running = _tab.RunAsync();
        await opening.Reached;
        var closing = _tab.CloseAsync();
        var waited = !closing.IsCompleted;
        opening.Open();
        await closing;
        await running;

        Assert.True(waited);
        var editor = Assert.Single(_session.Editors);
        Assert.Equal(1, editor.Disposals);
        Assert.Empty(editor.Runs);
        Assert.Equal(1, _session.Releases);
        Assert.Equal<string>(["clear"], _results.Shown);
        Assert.Equal<string>(["running", "idle", "editor closed"], _view.Shown);
    }

    [Fact]
    public async Task ATabClosedWhileItsRunIsReadStopsTheRunAndLetsGoOfEachPieceOnce()
    {
        var reading = new Gate();
        var run = FakeRun.Rows(5);
        run.Reading = reading;
        _session.Script = _ => run;

        var running = _tab.RunAsync();
        await reading.Reached;
        await _tab.CloseAsync();
        await running;

        var editor = Assert.Single(_session.Editors);
        Assert.Equal(1, run.Cancels);
        Assert.Equal(1, run.Disposals);
        Assert.Equal(1, editor.Disposals);
        Assert.Equal(1, _session.Releases);
        Assert.Equal<string>(["run", "clear"], _results.Shown);
        Assert.Equal<string>(["running", "idle", "editor closed"], _view.Shown);
    }

    [Fact]
    public async Task ATabClosedAfterItsRunWhileItLetsGoOfALostEditorSaysNothingMore()
    {
        _session.Script = _ => FakeRun.Rows(1, TransactionState.InTransaction);
        await _tab.RunAsync();
        var editor = Assert.Single(_session.Editors);
        var reading = new Gate();
        var run = FakeRun.Rows(1, TransactionState.InTransaction);
        run.Reading = reading;
        _session.Script = _ => run;
        var running = _tab.RunAsync();
        await reading.Reached;
        var disposing = new Gate();
        editor.Disposing = disposing;
        editor.IsLost = true;

        reading.Open();
        await disposing.Reached;
        var closing = _tab.CloseAsync();
        disposing.Open();
        await closing;
        await running;

        Assert.Equal(1, editor.Disposals);
        Assert.Equal(1, _session.Releases);
        Assert.Equal(TransactionState.Idle, _tab.Transaction);
        Assert.DoesNotContain("transaction lost", _view.Shown);
        Assert.Equal("clear", _results.Shown[^1]);
    }

    // Read as each run starts, so a change in Settings applies from the next run on.
    [Fact]
    public async Task EachRunKeepsTheResultsSettingsHeldWhenItStarted()
    {
        var settings = new AppSettings();
        var tab = new QueryTab("Query 2", _session, _view, _results, DataModel.Relational, () => settings);

        await tab.RunAsync();
        Assert.Equal(0, _results.KeptSets);

        settings = settings with { ResultSetsKeptPerRun = 50 };
        await tab.RunAsync();
        Assert.Equal(50, _results.KeptSets);
    }

    [Fact]
    public async Task ATabClosedAfterItsRunLetsGoOfEachPieceOnce()
    {
        await _tab.RunAsync();

        await Task.WhenAll(_tab.CloseAsync(), _tab.CloseAsync());
        await _tab.RunAsync();

        var editor = Assert.Single(_session.Editors);
        Assert.Equal(1, editor.Disposals);
        Assert.Single(editor.Runs);
        Assert.Equal(1, Assert.Single(editor.Started).Disposals);
        Assert.Equal(1, _session.Releases);
    }

    [Fact]
    public async Task ARunOnALostEditorThatHeldATransactionSaysSoAndRunsNothing()
    {
        _session.Script = _ => FakeRun.Rows(1, TransactionState.InTransaction);
        await _tab.RunAsync();
        var lost = Assert.Single(_session.Editors);
        lost.IsLost = true;

        await _tab.RunAsync();

        Assert.Single(lost.Runs);
        Assert.Equal(1, lost.Disposals);
        Assert.Single(_session.Editors);
        Assert.Contains("transaction lost", _view.Shown);
        Assert.Equal(TransactionState.Idle, _tab.Transaction);

        await _tab.RunAsync();

        Assert.Equal(2, _session.Editors.Count);
        Assert.Single(_session.Editors[1].Runs);
    }

    [Fact]
    public async Task ALostEditorWithNoTransactionIsReplacedAndTheRunGoesOn()
    {
        await _tab.RunAsync();
        var lost = Assert.Single(_session.Editors);
        lost.IsLost = true;

        await _tab.RunAsync();

        Assert.Equal(1, lost.Disposals);
        Assert.Equal(2, _session.Editors.Count);
        Assert.Single(_session.Editors[1].Runs);
        Assert.DoesNotContain("transaction lost", _view.Shown);
    }

    [Fact]
    public async Task ARunReadOnlyRefusesNeverStarts()
    {
        _session.Verdict = new RunGate(true, [], false);

        await _tab.RunAsync();

        Assert.Empty(_session.Editors);
        Assert.Contains("refused", _view.Shown);
        Assert.False(_tab.IsRunning);
    }

    [Fact]
    public async Task AWriteDeclinedAtTheQuestionNeverRuns()
    {
        _session.Verdict = new RunGate(false, ["delete from Artist"], true);
        _view.Confirm = _ => Task.FromResult(false);

        await _tab.RunAsync();

        Assert.Empty(_session.Editors);
        Assert.Contains("asked Chinook", _view.Shown);
    }

    [Fact]
    public async Task AWriteConfirmedAtTheQuestionRuns()
    {
        _session.Verdict = new RunGate(false, ["delete from Artist"], true);
        _view.WholeText = "delete from Artist";

        await _tab.RunAsync();

        Assert.Equal<string>(["delete from Artist"], Assert.Single(_session.Editors).Runs);
    }

    [Fact]
    public async Task ATabClosedWhileItsQuestionIsOpenNeverRuns()
    {
        _session.Verdict = new RunGate(false, ["delete from Artist"], false);
        var answer = new TaskCompletionSource<bool>(TaskCreationOptions.RunContinuationsAsynchronously);
        _view.Confirm = _ => answer.Task;

        var running = _tab.RunAsync();
        await _tab.RunAsync();
        await _tab.CloseAsync();
        answer.SetResult(true);
        await running;

        Assert.Equal(1, _session.GateRuns);
        Assert.Empty(_session.Editors);
        Assert.Equal(1, _session.Releases);
    }

    [Fact]
    public async Task CommitAndRollBackEndTheTransactionWithoutSafeModeAsking()
    {
        _session.Script = _ => FakeRun.Rows(0, TransactionState.InTransaction);
        await _tab.RunAsync();
        Assert.Equal(TransactionState.InTransaction, _tab.Transaction);
        Assert.True(_view.CanCommit);
        _session.Verdict = new RunGate(true, [], false);

        await _tab.CommitAsync();
        await _tab.RollBackAsync();

        Assert.Equal<string>(["select * from Artist", "COMMIT", "ROLLBACK"], Assert.Single(_session.Editors).Runs);
        Assert.Equal(1, _session.GateRuns);
        Assert.DoesNotContain("refused", _view.Shown);
    }

    [Fact]
    public async Task TheSqlOfTheResultShownIsTheLastTypedRunAndCommitClearsIt()
    {
        _session.Script = _ => FakeRun.Rows(1, TransactionState.InTransaction);
        Assert.Null(_tab.LastStatement);

        _view.SelectedText = "select 1";
        await _tab.RunAsync();
        var ran = _tab.LastStatement;
        _session.Verdict = new RunGate(true, [], false);
        await _tab.CommitAsync();

        Assert.Equal("select 1", ran);
        Assert.Null(_tab.LastStatement);
    }

    [Fact]
    public async Task ARollBackDeclinedSendsNothingAndAKeyValueEngineEndsWithItsOwnCommands()
    {
        var tab = new QueryTab("Query 1", _session, _view, _results, DataModel.KeyValue, () => new AppSettings());
        _session.Script = _ => FakeRun.Rows(0, TransactionState.InTransaction);
        await tab.RunAsync();
        _view.RollsBack = false;

        await tab.RollBackAsync();
        await tab.CommitAsync();
        _view.RollsBack = true;
        await tab.RollBackAsync();

        Assert.Equal<string>(["select * from Artist", "EXEC", "DISCARD"], Assert.Single(_session.Editors).Runs);
    }

    [Fact]
    public async Task AFailedTransactionOrAReadOnlyConnectionOffersOnlyRollBack()
    {
        _session.IsReadOnly = true;
        _session.Script = _ => FakeRun.Rows(0, TransactionState.InTransaction);
        await _tab.RunAsync();
        Assert.False(_view.CanCommit);

        _session.IsReadOnly = false;
        _session.Script = _ => FakeRun.Rows(0, TransactionState.Failed);
        await _tab.RunAsync();

        Assert.False(_view.CanCommit);
        Assert.Equal(TransactionState.Failed, _tab.Transaction);
    }

    [Fact]
    public async Task ASortRunsTheStatementAgainWithoutSafeModeAsking()
    {
        _session.Sorted = (sql, columns, column, _) => $"{sql} order by {columns[column]}";
        await _tab.RunAsync();
        _session.Verdict = new RunGate(true, [], false);
        var sort = new GridSort(1, SortDirection.Ascending);

        await _tab.SortAsync(sort);

        Assert.Equal("select * from Artist order by name", Assert.Single(_session.Editors).Runs[^1]);
        Assert.Equal(sort, _results.RunSort);
        Assert.Equal(1, _session.GateRuns);
    }

    [Fact]
    public async Task ASortThatCannotRunAgainSortsTheRowsHeld()
    {
        _session.Script = _ => FakeRun.Rows(7);
        await _tab.RunAsync();
        var sort = new GridSort(0, SortDirection.Descending);

        await _tab.SortAsync(sort);

        Assert.Single(Assert.Single(_session.Editors).Runs);
        Assert.Contains("sort held", _results.Shown);
        Assert.Contains("sorted held 7", _view.Shown);
        Assert.Equal(sort, _results.Sort);
    }

    [Fact]
    public async Task AScriptIsNeverRunAgainToSortAndARefusedHeldSortKeepsTheShownOne()
    {
        var asked = 0;
        _session.Sorted = (sql, _, _, _) =>
        {
            asked++;
            return sql;
        };
        _session.Script = _ => FakeRun.Script();
        await _tab.RunAsync();
        _results.SortsHeldRows = false;

        await _tab.SortAsync(new GridSort(0, SortDirection.Ascending));

        Assert.Equal(0, asked);
        Assert.Single(Assert.Single(_session.Editors).Runs);
        Assert.Equal(GridSort.None, _results.Sort);
    }

    [Fact]
    public async Task RunStatementSelectsTheStatementAtTheCaretAndRunsOnlyIt()
    {
        _view.WholeText = "select 1; select 2";
        _view.Caret = 12;
        _session.Statement = (_, caret) => caret >= 10 ? new Range(10, 18) : new Range(0, 8);

        await _tab.RunStatementAsync();

        Assert.Contains("selected 10 8", _view.Shown);
        Assert.Equal<string>(["select 2"], Assert.Single(_session.Editors).Runs);
    }

    [Fact]
    public async Task RunStatementWithNoStatementAtTheCaretSaysSoAndRunsNothing()
    {
        await _tab.RunStatementAsync();

        Assert.Contains("no statement", _view.Shown);
        Assert.Empty(_session.Editors);
        Assert.Equal(0, _session.GateRuns);
    }

    [Fact]
    public async Task ARunSendsTheSelectionOrTheWholeTextWhenNothingIsSelected()
    {
        _view.SelectedText = "select 2";
        await _tab.RunAsync();
        _view.SelectedText = "  ";
        await _tab.RunAsync();

        Assert.Equal<string>(["select 2", "select * from Artist"], Assert.Single(_session.Editors).Runs);
        Assert.Equal(
            new SessionTab { Kind = TabKind.Query, Title = "Query 1", Sql = "select * from Artist", WrapText = false },
            _tab.Snapshot());
        Assert.False(_tab.HasUnsavedChanges);
    }

    [Fact]
    public void ANewTabWrapsAsSettingsSayAndAnOpenTabNeverFollowsAChange()
    {
        var settings = new AppSettings { GridWrapText = true };
        var tab = new QueryTab("Query 2", _session, _view, _results, DataModel.Relational, () => settings);

        settings = new AppSettings();

        Assert.False(_tab.WrapsText);
        Assert.True(tab.WrapsText);
        Assert.True(tab.Snapshot().WrapText);
    }

    [Fact]
    public void ATabsOwnWrapChoiceIsKeptInItsSnapshotAndToldOnce()
    {
        var changes = 0;
        _tab.StateChanged += (_, _) => changes++;

        _tab.SetWrapsText(true);
        _tab.SetWrapsText(true);

        Assert.True(_tab.WrapsText);
        Assert.Equal(1, changes);
        Assert.True(_tab.Snapshot().WrapText);
    }

    [Fact]
    public void ARestoredTabKeepsItsWrapChoiceWhateverSettingsSayNow()
    {
        var wrapping = new AppSettings { GridWrapText = true };
        var kept = new QueryTab(
            "Query 2", _session, _view, _results, DataModel.Relational, () => wrapping, wrapText: false);
        var older = new QueryTab("Query 3", _session, _view, _results, DataModel.Relational, () => wrapping);

        Assert.False(kept.WrapsText);
        Assert.True(older.WrapsText);
    }

    [Fact]
    public void TheSnapshotKeepsTheFoldedLinesAndNoneWhenNothingIsFolded()
    {
        Assert.Null(_tab.Snapshot().FoldedLines);

        _view.FoldedLines = [2, 9];

        Assert.Equal<int>([2, 9], _tab.Snapshot().FoldedLines!);
    }

    // The server counts code points from 1; the document keeps "\r\n" and a lone '\r' as one '\n'.
    [Theory]
    [InlineData(10, "select nope", 8, 17)]
    [InlineData(5, "select '\U0001F600', nope", 13, 18)]
    [InlineData(0, "select 1;\r\nselect nope", 19, 17)]
    [InlineData(0, "select 1;\rselect nope", 18, 17)]
    [InlineData(4, "select", 99, 10)]
    public void AServerErrorPlaceBecomesTheOffsetTheDocumentHoldsIt(int start, string sent, int position, int offset) =>
        Assert.Equal<int?>(offset, QueryTab.ErrorOffset(start, sent, position));

    [Fact]
    public void AServerErrorPlaceBeforeTheFirstCharacterIsNone()
    {
        Assert.Null(QueryTab.ErrorOffset(10, "select nope", 0));
        Assert.Null(QueryTab.ErrorOffset(10, "select nope", -3));
    }

    [Fact]
    public async Task RunStatementThatFailsAtAPlaceOffersItCountedFromTheStatementsStart()
    {
        _view.WholeText = "select 1;\nselect nope";
        _view.Caret = 15;
        _session.Statement = (_, caret) => caret >= 10 ? new Range(10, 21) : new Range(0, 9);
        _session.Script = _ => FakeRun.Ending(new QueryOutcome.Failed(FailedAt(8)));

        await _tab.RunStatementAsync();

        Assert.Equal<string>(["select nope"], Assert.Single(_session.Editors).Runs);
        Assert.Contains("error at 17", _view.Shown);
    }

    [Fact]
    public async Task ASelectionThatFailsAtAPlaceOffersItCountedFromWhereTheSelectionStarts()
    {
        _view.WholeText = "select 1;\nselect nope";
        _view.SelectedText = "select nope";
        _view.SelectedTextStart = 10;
        _session.Script = _ => FakeRun.Ending(new QueryOutcome.Failed(FailedAt(8)));

        await _tab.RunAsync();

        Assert.Contains("error at 17", _view.Shown);
    }

    // The whole text is sent with the file's own line breaks, which the document keeps as one '\n' each.
    [Fact]
    public async Task TheWholeTextThatFailsAtAPlaceOffersTheOffsetTheDocumentHoldsIt()
    {
        _view.WholeText = "select 1;\r\nselect nope";
        _session.Script = _ => FakeRun.Ending(new QueryOutcome.Failed(FailedAt(19)));

        await _tab.RunAsync();

        Assert.Contains("error at 17", _view.Shown);
    }

    [Fact]
    public async Task ARunOfSeveralSelectionsOffersNoPlace()
    {
        _view.SelectedText = "select nope\nselect 2";
        _view.SelectedTextStart = null;
        _session.Script = _ => FakeRun.Ending(new QueryOutcome.Failed(FailedAt(8)));

        await _tab.RunAsync();

        Assert.Equal<string>(["select nope\nselect 2"], Assert.Single(_session.Editors).Runs);
        Assert.DoesNotContain(_view.Shown, shown => shown.StartsWith("error at", StringComparison.Ordinal));
    }

    [Fact]
    public async Task ARunThatCompletesOffersNoPlace()
    {
        _view.SelectedText = "select 2";
        _view.SelectedTextStart = 4;

        await _tab.RunAsync();

        Assert.Single(Assert.Single(_session.Editors).Runs);
        Assert.DoesNotContain(_view.Shown, shown => shown.StartsWith("error at", StringComparison.Ordinal));
    }

    [Fact]
    public async Task ASortTheServerFailsAtAPlaceOffersNoPlace()
    {
        _session.Sorted = (sql, _, _, _) => sql + " ORDER BY 1";
        await _tab.RunAsync();
        _session.Script = _ => FakeRun.Ending(new QueryOutcome.Failed(FailedAt(8)));

        await _tab.SortAsync(new GridSort(0, SortDirection.Ascending));

        Assert.Equal(2, Assert.Single(_session.Editors).Runs.Count);
        Assert.DoesNotContain(_view.Shown, shown => shown.StartsWith("error at", StringComparison.Ordinal));
    }

    [Fact]
    public void ATypedNameIsTheTitleAndTheSnapshotKeepsItApartFromTheAutomaticOne()
    {
        var changes = 0;
        _tab.StateChanged += (_, _) => changes++;

        Assert.True(_tab.CanRename);
        Assert.True(_tab.Rename("  Monthly report\t"));

        Assert.Equal("Monthly report", _tab.Title);
        Assert.Equal("Query 1", _tab.AutomaticTitle);
        Assert.Equal(1, changes);
        var snapshot = _tab.Snapshot();
        Assert.Equal(("Query 1", "Monthly report"), (snapshot.Title, snapshot.CustomTitle));
    }

    [Fact]
    public void TheSameNameAgainChangesNothingAndAnEmptyOneGoesBackToTheAutomaticTitle()
    {
        _tab.Rename("Report");
        var changes = 0;
        _tab.StateChanged += (_, _) => changes++;

        Assert.False(_tab.Rename("Report "));
        Assert.Equal(0, changes);

        Assert.True(_tab.Rename(" \u200B "));

        Assert.Equal("Query 1", _tab.Title);
        Assert.Null(_tab.CustomTitle);
        Assert.Null(_tab.Snapshot().CustomTitle);
        Assert.Equal(1, changes);
        Assert.False(_tab.Rename(string.Empty));
    }

    // Typed by the user, so it stays as typed even when it reads like a number the app gives.
    [Fact]
    public void ANameThatReadsLikeAnAutomaticTitleIsStillTyped()
    {
        Assert.True(_tab.Rename("Query 7"));

        Assert.Equal("Query 7", _tab.CustomTitle);
        Assert.Equal("Query 1", _tab.Snapshot().Title);
    }

    [Fact]
    public void ARestoredNameShowsAndABlankOneIsNone()
    {
        var named = new QueryTab(
            "Query 3", _session, _view, _results, DataModel.Relational, () => new AppSettings(), customTitle: "Report");
        var blank = new QueryTab(
            "Query 4", _session, _view, _results, DataModel.Relational, () => new AppSettings(), customTitle: "\u200D ");

        Assert.Equal(("Report", "Query 3"), (named.Title, named.AutomaticTitle));
        Assert.Equal("Query 4", blank.Title);
        Assert.Null(blank.CustomTitle);
    }

    [Fact]
    public async Task AClosedTabCannotBeRenamed()
    {
        await _tab.CloseAsync();

        Assert.False(_tab.CanRename);
        Assert.False(_tab.Rename("Late"));
        Assert.Equal("Query 1", _tab.Title);
    }

    [Theory]
    [InlineData("a\r\n\tb", "a b")]
    [InlineData("a\u2028b\u2029c", "a b c")]
    [InlineData("\u200B\uFEFF ", null)]
    [InlineData("\u200D", null)]
    [InlineData("\U0001F468\u200D\U0001F469", "\U0001F468\u200D\U0001F469")]
    [InlineData("  Sales by region  ", "Sales by region")]
    [InlineData("", null)]
    public void ATypedNameIsCleanedOnceAsItIsKept(string typed, string? kept) =>
        Assert.Equal(kept, QueryTitles.Normalize(typed));

    [Fact]
    public void ALongNameIsCutAtAHundredGraphemesWithoutSplittingOne()
    {
        var family = "\U0001F468\u200D\U0001F469\u200D\U0001F467";

        var cut = QueryTitles.Normalize(string.Concat(Enumerable.Repeat(family, 101)));
        var spaced = QueryTitles.Normalize(new string('a', 99) + " " + new string('b', 10));

        Assert.Equal(string.Concat(Enumerable.Repeat(family, 100)), cut);
        Assert.Equal(new string('a', 99), spaced);
    }

    [Fact]
    public void TheNextAutomaticTitleSkipsEveryTitleShownOrHidden()
    {
        var taken = new HashSet<string> { "Query 1", "Query 2", "Report", "Query 4" };

        Assert.Equal("Query 3", QueryTitles.Next(taken, "Query {0}"));
        Assert.Equal("Query 1", QueryTitles.Next(new HashSet<string>(), "Query {0}"));
    }

    [Theory]
    [InlineData("Query 7", true)]
    [InlineData("Query 07", false)]
    [InlineData("Query +7", false)]
    [InlineData("Query 0", false)]
    [InlineData("Query 7 ", false)]
    [InlineData("Query ", false)]
    [InlineData("Query 99999999999", false)]
    [InlineData("Report", false)]
    public void OnlyATitleTheAppWouldNumberCountsAsNumbered(string title, bool numbered) =>
        Assert.Equal(numbered, QueryTitles.IsNumbered(title, "Query {0}"));

    private static CoreError FailedAt(int position) => new(
        "driver.server",
        ["driver.server"],
        "column \"nope\" does not exist",
        new ServerMessage("column \"nope\" does not exist", null, "42703", null, null, position),
        null);
}
