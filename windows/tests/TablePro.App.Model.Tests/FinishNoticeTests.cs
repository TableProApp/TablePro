using TablePro.DataGrid.Model;
using TablePro.Interop;

namespace TablePro.App.Model.Tests;

public sealed class FinishNoticeTests
{
    private static readonly AppSettings Settings = new() { NotifyAfterSeconds = 20 };

    [Fact]
    public void OnlyLongWorkTheUserIsNotLookingAtNotifies()
    {
        var finished = new RunEnd(TimeSpan.FromSeconds(20), false, null, 3, null);

        Assert.True(FinishNotice.Tells(Settings, finished, inView: false));
        Assert.False(FinishNotice.Tells(Settings, finished, inView: true));
        Assert.False(FinishNotice.Tells(Settings, finished with { Elapsed = TimeSpan.FromSeconds(19.9) }, inView: false));
        Assert.False(FinishNotice.Tells(Settings, finished with { Cancelled = true }, inView: false));
        Assert.False(FinishNotice.Tells(Settings with { NotifyLongWork = false }, finished, inView: false));
        Assert.True(FinishNotice.Tells(Settings, finished with { Failure = "syntax error" }, inView: false));
    }

    [Theory]
    [InlineData(0, "0s")]
    [InlineData(45.4, "45s")]
    [InlineData(192, "3m 12s")]
    [InlineData(3_720, "1h 2m")]
    public void ADurationKeepsItsTwoLargestUnits(double seconds, string text) =>
        Assert.Equal(text, FinishNotice.Duration(TimeSpan.FromSeconds(seconds)));

    [Fact]
    public void AThresholdSettingsDoNotOfferFallsBackToTheDefault()
    {
        Assert.Equal(AppSettings.DefaultNotifyAfterSeconds, new AppSettings { NotifyAfterSeconds = 7 }.Normalized().NotifyAfterSeconds);
        Assert.Equal(600, new AppSettings { NotifyAfterSeconds = 600 }.Normalized().NotifyAfterSeconds);
        Assert.True(new AppSettings().NotifyLongWork);
    }
}

public sealed class QueryTabRunEndTests
{
    private readonly FakeSession _session = new();
    private readonly FakeQueryView _view = new();
    private readonly FakeResults _results = new();
    private readonly QueryTab _tab;
    private readonly List<RunEnd> _ended = [];

    public QueryTabRunEndTests()
    {
        _tab = new QueryTab("Query 1", _session, _view, _results, DataModel.Relational, () => new AppSettings());
        _tab.RunEnded += (_, end) => _ended.Add(end);
    }

    [Fact]
    public async Task AFinishedRunEndsWithItsRows()
    {
        _session.Script = _ => FakeRun.Rows(1_204);

        await _tab.RunAsync();

        var end = Assert.Single(_ended);
        Assert.Equal(1_204, end.Rows);
        Assert.False(end.Cancelled);
        Assert.Null(end.Failure);
    }

    [Fact]
    public async Task AFailedRunEndsWithTheErrorInTheViewsWords()
    {
        _session.Script = _ => FakeRun.Ending(new QueryOutcome.Failed(Errors.Of("query.syntax")));

        await _tab.RunAsync();

        Assert.Equal("worded query.syntax", Assert.Single(_ended).Failure);
    }

    [Fact]
    public async Task AStoppedRunEndsCancelled()
    {
        _session.Script = _ => FakeRun.Ending(new QueryOutcome.Cancelled());

        await _tab.RunAsync();

        Assert.True(Assert.Single(_ended).Cancelled);
    }

    [Fact]
    public async Task ASortCommitAndRollBackEndNoRunOfTheUsers()
    {
        _session.Sorted = (sql, columns, column, _) => $"{sql} order by {columns[column]}";
        _session.Script = _ => FakeRun.Rows(1, TransactionState.InTransaction);
        await _tab.RunAsync();

        await _tab.SortAsync(new GridSort(1, SortDirection.Ascending));
        await _tab.CommitAsync();
        await _tab.RollBackAsync();

        Assert.Single(_ended);
    }
}
