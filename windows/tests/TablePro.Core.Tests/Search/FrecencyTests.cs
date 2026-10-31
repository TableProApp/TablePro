using TablePro.Core.Search;

namespace TablePro.Core.Tests.Search;

public sealed class FrecencyTests
{
    private static readonly DateTimeOffset Now = new(2026, 10, 28, 12, 0, 0, TimeSpan.Zero);

    [Fact]
    public void RecentAndFrequentOutranksOldAndRare()
    {
        var frecency = new Frecency();
        frecency.Record("orders", Now.AddDays(-1));
        frecency.Record("orders", Now.AddHours(-2));
        frecency.Record("archive", Now.AddDays(-200));

        Assert.True(frecency.Score("orders", Now) > frecency.Score("archive", Now));
        Assert.Equal(0, frecency.Score("never", Now));
    }

    [Fact]
    public void ScoreIsCappedAtOne()
    {
        var frecency = new Frecency();
        for (var i = 0; i < 30; i++)
        {
            frecency.Record("orders", Now.AddMinutes(-i));
        }

        Assert.Equal(1, frecency.Score("orders", Now));
    }

    [Fact]
    public void RecentIdsAreNewestFirstAndSurviveASnapshot()
    {
        var frecency = new Frecency();
        frecency.Record("a", Now.AddDays(-3));
        frecency.Record("b", Now.AddDays(-1));
        frecency.Record("c", Now.AddDays(-2));

        var restored = new Frecency();
        restored.Load(frecency.Snapshot());

        Assert.Equal(["b", "c", "a"], restored.RecentIds());
    }

    [Fact]
    public void KeepsOnlyTheHundredMostRecentItems()
    {
        var frecency = new Frecency();
        for (var i = 0; i < 120; i++)
        {
            frecency.Record($"t{i}", Now.AddMinutes(i));
        }

        var ids = frecency.RecentIds();
        Assert.Equal(100, ids.Count);
        Assert.Equal("t119", ids[0]);
        Assert.DoesNotContain("t0", ids);
    }
}
