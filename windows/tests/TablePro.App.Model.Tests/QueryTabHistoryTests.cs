using TablePro.DataGrid.Model;
using TablePro.Interop;

namespace TablePro.App.Model.Tests;

public sealed class QueryTabHistoryTests
{
    private readonly FakeSession _session = new();
    private readonly FakeQueryView _view = new();
    private readonly FakeResults _results = new();
    private readonly FakeHistoryRecorder _history = new();
    private readonly QueryTab _tab;

    public QueryTabHistoryTests()
    {
        _tab = new QueryTab(
            "Query 1",
            _session,
            _view,
            _results,
            DataModel.Relational,
            () => new AppSettings(),
            _history);
    }

    [Fact]
    public async Task AFinishedRunIsKeptWithItsStartTheCoresTimeAndTheRowsItsStatementsChanged()
    {
        _view.WholeText = "update Artist set Name = 'A'; delete from Album; create table T (id int)";
        _session.Script = _ => Ending(new QueryOutcome.Completed(TimeSpan.FromMilliseconds(40)), [3, 2, null]);
        var before = DateTimeOffset.Now;

        await _tab.RunAsync();

        var run = Assert.Single(_history.Runs);
        Assert.Equal(_view.WholeText, run.Sql);
        Assert.InRange(run.ExecutedAt, before, DateTimeOffset.Now);
        Assert.Equal(TimeSpan.FromMilliseconds(40), run.Duration);
        Assert.Equal(5L, run.RowsAffected);
        Assert.Same(HistoryOutcome.Succeeded.Instance, run.Outcome);
    }

    [Fact]
    public async Task AReadIsKeptWithNoRowsAffected()
    {
        await _tab.RunAsync();

        var run = Assert.Single(_history.Runs);
        Assert.Equal("select * from Artist", run.Sql);
        Assert.Null(run.RowsAffected);
        Assert.Equal(TimeSpan.FromMilliseconds(12), run.Duration);
    }

    [Fact]
    public async Task AFailedRunIsKeptWithTheErrorInTheWordsTheViewShowed()
    {
        _session.Script = _ => Ending(new QueryOutcome.Failed(Errors.Of("query.syntax")));

        await _tab.RunAsync();

        var run = Assert.Single(_history.Runs);
        Assert.Equal(new HistoryOutcome.Failed("worded query.syntax"), run.Outcome);
        Assert.NotNull(run.Duration);
        Assert.Null(run.RowsAffected);
    }

    [Fact]
    public async Task AStoppedRunIsKeptAsCancelled()
    {
        var reading = new Gate();
        var stopped = Ending(new QueryOutcome.Cancelled());
        stopped.Reading = reading;
        _session.Script = _ => stopped;

        var running = _tab.RunAsync();
        await reading.Reached;
        _tab.Stop();
        reading.Open();
        await running;

        Assert.Equal(1, stopped.Cancels);
        var run = Assert.Single(_history.Runs);
        Assert.Same(HistoryOutcome.Cancelled.Instance, run.Outcome);
        Assert.NotNull(run.Duration);
    }

    [Fact]
    public async Task ARunPastTheTimeLimitIsKeptAsAFailureInTheViewsWords()
    {
        _session.Script = _ => Ending(new QueryOutcome.TimedOut(ServerCancelled: true));

        await _tab.RunAsync();

        Assert.Equal(new HistoryOutcome.Failed("timed out"), Assert.Single(_history.Runs).Outcome);
    }

    [Fact]
    public async Task RunStatementKeepsOnlyTheStatementItSent()
    {
        _view.WholeText = "select 1; select 2";
        _view.Caret = 12;
        _session.Statement = (_, _) => new Range(10, 18);

        await _tab.RunStatementAsync();

        Assert.Equal("select 2", Assert.Single(_history.Runs).Sql);
    }

    [Fact]
    public async Task ASortThatRunsTheStatementAgainCommitAndRollBackAreNotKept()
    {
        _session.Sorted = (sql, columns, column, _) => $"{sql} order by {columns[column]}";
        _session.Script = _ => FakeRun.Rows(1, TransactionState.InTransaction);
        await _tab.RunAsync();

        await _tab.SortAsync(new GridSort(1, SortDirection.Ascending));
        await _tab.CommitAsync();
        await _tab.RollBackAsync();

        Assert.Equal<string>(
            ["select * from Artist", "select * from Artist order by name", "COMMIT", "ROLLBACK"],
            Assert.Single(_session.Editors).Runs);
        Assert.Equal("select * from Artist", Assert.Single(_history.Runs).Sql);
    }

    [Fact]
    public async Task ARunSafeModeRefusesOrTheUserDeclinesIsNotKept()
    {
        _session.Verdict = new RunGate(true, [], false);
        await _tab.RunAsync();
        _session.Verdict = new RunGate(false, ["delete from Artist"], true);
        _view.Confirm = _ => Task.FromResult(false);
        await _tab.RunAsync();

        Assert.Empty(_session.Editors);
        Assert.Empty(_history.Runs);
    }

    [Fact]
    public async Task ARunThatNeverStartsIsNotKept()
    {
        _session.Script = _ => FakeRun.Rows(1, TransactionState.InTransaction);
        await _tab.RunAsync();
        Assert.Single(_session.Editors).IsLost = true;

        await _tab.RunAsync();
        _view.WholeText = "   ";
        await _tab.RunAsync();

        Assert.Contains("transaction lost", _view.Shown);
        Assert.Single(_history.Runs);
    }

    [Fact]
    public async Task ARunTheTabClosedDuringIsNotKeptEvenWhenItEnds()
    {
        var reading = new Gate(honorsCancel: false);
        var run = FakeRun.Rows(1);
        run.Reading = reading;
        _session.Script = _ => run;

        var running = _tab.RunAsync();
        await reading.Reached;
        var closing = _tab.CloseAsync();
        reading.Open();
        await closing;
        await running;
        await _tab.RunAsync();

        Assert.Empty(_history.Runs);
        Assert.Equal(1, _session.Releases);
    }

    [Fact]
    public async Task TheTabIsIdleBeforeItsRunIsWrittenAndACloseWaitsForTheWriteBeforeLettingTheSessionGo()
    {
        var recording = new Gate();
        _history.Recording = recording;

        var running = _tab.RunAsync();
        await recording.Reached;

        Assert.False(_tab.IsRunning);
        Assert.Equal("idle", _view.Shown[^1]);

        var closing = _tab.CloseAsync();
        var waited = !closing.IsCompleted && _session.Releases == 0;
        recording.Open();
        await closing;
        await running;

        Assert.True(waited);
        Assert.Single(_history.Runs);
        Assert.Equal(1, _session.Releases);
    }

    [Fact]
    public async Task AHistoryThatCannotBeWrittenLeavesTheRunAsItEnded()
    {
        _history.Failure = Errors.Of("history.unavailable");

        await _tab.RunAsync();

        Assert.Single(_history.Runs);
        Assert.False(_tab.IsRunning);
        Assert.Equal<string>(["run"], _results.Shown);
    }

    // One statement per count, each reporting it, then the run's end.
    private static FakeRun Ending(QueryOutcome outcome, IReadOnlyList<long?>? affected = null) => new(
    [
        .. (affected ?? []).Select(rows => new QueryEvent.CommandCompleted(rows)),
        new QueryEvent.Finished(outcome, TransactionState.Idle),
    ]);
}

internal sealed class FakeHistoryRecorder : IHistoryRecorder
{
    public List<HistoryRun> Runs { get; } = [];

    // Waited at by each write, which is never cancelled.
    public Gate? Recording { get; set; }

    public CoreError? Failure { get; set; }

    public async Task RecordAsync(HistoryRun run)
    {
        Runs.Add(run);
        if (Recording is { } recording)
        {
            await recording.PassAsync(CancellationToken.None);
        }

        if (Failure is { } failure)
        {
            throw new TableProException(failure);
        }
    }
}
