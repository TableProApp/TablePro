using TablePro.Core.Interaction;

namespace TablePro.Core.Tests.Interaction;

public sealed class RepeatClickFilterTests
{
    private static readonly TimeSpan DoubleClick = TimeSpan.FromMilliseconds(500);

    [Fact]
    public void TheSecondClickOfADoubleClickIsDropped()
    {
        var filter = new RepeatClickFilter(DoubleClick);

        Assert.True(filter.ShouldAct("reports", TimeSpan.FromMilliseconds(1000)));
        Assert.False(filter.ShouldAct("reports", TimeSpan.FromMilliseconds(1200)));
    }

    [Fact]
    public void ClicksFurtherApartEachAct()
    {
        var filter = new RepeatClickFilter(DoubleClick);

        Assert.True(filter.ShouldAct("reports", TimeSpan.FromMilliseconds(1000)));
        Assert.True(filter.ShouldAct("reports", TimeSpan.FromMilliseconds(1600)));
    }

    [Fact]
    public void AQuickClickOnAnotherRowActs()
    {
        var filter = new RepeatClickFilter(DoubleClick);

        Assert.True(filter.ShouldAct("reports", TimeSpan.FromMilliseconds(1000)));
        Assert.True(filter.ShouldAct("monthly", TimeSpan.FromMilliseconds(1100)));
    }

    [Fact]
    public void ATripleClickTogglesTwice()
    {
        var filter = new RepeatClickFilter(DoubleClick);

        Assert.True(filter.ShouldAct("reports", TimeSpan.FromMilliseconds(1000)));
        Assert.False(filter.ShouldAct("reports", TimeSpan.FromMilliseconds(1150)));
        Assert.True(filter.ShouldAct("reports", TimeSpan.FromMilliseconds(1300)));
    }
}
