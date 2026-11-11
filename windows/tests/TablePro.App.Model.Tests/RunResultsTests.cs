using TablePro.Interop;

namespace TablePro.App.Model.Tests;

public sealed class RunResultsTests
{
    private static readonly ResultColumn[] Columns = [new("id", "INTEGER", ValueKind.Integer)];

    [Fact]
    public void EverySetOfARunIsListedInTheOrderItStarted()
    {
        var results = New();
        var first = results.Add(0, Columns);
        var second = results.Add(1, Columns);

        results.Apply(new QueryEvent.ResultSetFinished(0, 3, null, Truncation.Complete));
        results.Apply(new QueryEvent.RowsAppended(1, 40));
        results.Apply(new QueryEvent.ResultSetFinished(1, 50, null, Truncation.Complete));

        Assert.Equal([first, second], results.Results);
        Assert.Equal(3, first.Rows);
        Assert.Equal(50, second.Rows);
        Assert.Equal(["Result 1 (3)", "Result 2 (50)"], results.Results.Select(results.Label));
    }

    [Fact]
    public void RowsOfOneSetNeverCountTowardAnother()
    {
        var results = New();
        var first = results.Add(0, Columns);
        results.Add(1, Columns);

        var changed = results.Apply(new QueryEvent.RowsAppended(1, 7));

        Assert.NotSame(first, changed);
        Assert.Equal(0, first.Rows);
        Assert.Equal(7, changed?.Rows);
    }

    [Fact]
    public void ASetTheLimitCutShortShowsTheCountedTotalOrAPlus()
    {
        var results = New();
        var counted = results.Add(0, Columns);
        var uncounted = results.Add(1, Columns);

        results.Apply(new QueryEvent.ResultSetFinished(0, 10_000, 25_000, Truncation.ReadPastLimit));
        results.Apply(new QueryEvent.RowLimitReached(1, 10_000));
        results.Apply(new QueryEvent.ResultSetFinished(1, 10_000, null, Truncation.ServerStopped));

        Assert.True(counted.Truncated);
        Assert.True(uncounted.Truncated);
        Assert.Equal("Result 1 (25000)", results.Label(counted));
        Assert.Equal("Result 2 (10000+)", results.Label(uncounted));
    }

    [Fact]
    public void EventsAboutNoListedSetChangeNothing()
    {
        var results = New();
        var only = results.Add(0, Columns);

        Assert.Null(results.Apply(new QueryEvent.RowsAppended(4, 9)));
        Assert.Null(results.Apply(new QueryEvent.CommandCompleted(2)));
        Assert.Equal(0, only.Rows);
    }

    // No number format, so the labels read the same under every culture.
    private static RunResults New() => new("Result {0} ({1})", "Result {0} ({1}+)");
}
