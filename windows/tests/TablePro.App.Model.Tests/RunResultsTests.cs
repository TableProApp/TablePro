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
        Assert.False(counted.StoppedOnServer);
        Assert.True(uncounted.StoppedOnServer);
        Assert.Equal("Result 1 (25000)", results.Label(counted));
        Assert.Equal("Result 2 (10000+)", results.Label(uncounted));
    }

    [Fact]
    public void ASetCutForSizeKeepsTheRunsLimitAndShowsAPlusWhenNobodyCounted()
    {
        var results = New();
        var uncounted = results.Add(0, Columns);
        var counted = results.Add(1, Columns);
        var rowLimited = results.Add(2, Columns);

        results.Apply(new QueryEvent.RowsAppended(0, 16));
        results.Apply(new QueryEvent.ByteLimitReached(0, 16, 256_000_000));
        results.Apply(new QueryEvent.ResultSetFinished(0, 16, null, Truncation.ByteLimit));
        results.Apply(new QueryEvent.ByteLimitReached(1, 0, 256_000_000));
        results.Apply(new QueryEvent.ResultSetFinished(1, 0, 100, Truncation.ByteLimit));
        results.Apply(new QueryEvent.ResultSetFinished(2, 10_000, 25_000, Truncation.ReadPastLimit));

        Assert.True(uncounted.Truncated);
        Assert.Equal(256_000_000, uncounted.SizeLimit);
        Assert.False(uncounted.StoppedOnServer);
        Assert.Equal(256_000_000, counted.SizeLimit);
        Assert.Null(rowLimited.SizeLimit);
        Assert.Equal("Result 1 (16+)", results.Label(uncounted));
        Assert.Equal("Result 2 (100)", results.Label(counted));
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

    // A script of one statement per sequence returns a set per statement, and each event finds its own.
    [Fact]
    public void TenThousandSetsEachTakeTheirOwnRowsAndPlace()
    {
        var results = New();
        var sets = Enumerable.Range(0, 10_000).Select(index => results.Add(index * 2, Columns)).ToList();

        foreach (var index in Enumerable.Range(0, sets.Count).Reverse())
        {
            results.Apply(new QueryEvent.RowsAppended(index * 2, index));
            results.Apply(new QueryEvent.ResultSetFinished(index * 2, index + 1, null, Truncation.Complete));
        }

        Assert.Null(results.Apply(new QueryEvent.RowsAppended(1, 5)));
        Assert.Equal(Enumerable.Range(1, sets.Count).Select(rows => (long)rows), sets.Select(set => set.Rows));
        Assert.Equal("Result 1 (1)", results.Label(sets[0]));
        Assert.Equal("Result 10000 (10000)", results.Label(sets[^1]));
    }

    [Fact]
    public void TwoSetsWithOneIndexLeaveTheEventsToTheFirst()
    {
        var results = New();
        var first = results.Add(3, Columns);
        var second = results.Add(3, Columns);

        Assert.Same(first, results.Apply(new QueryEvent.RowsAppended(3, 8)));
        Assert.Equal(0, second.Rows);
        Assert.Equal("Result 2 (0)", results.Label(second));
    }

    // No number format, so the labels read the same under every culture.
    private static RunResults New() => new("Result {0} ({1})", "Result {0} ({1}+)");
}
