using TablePro.Core.Interaction;

namespace TablePro.Core.Tests.Interaction;

public sealed class SplitterMathTests
{
    // The query tab: a 48 px toolbar, the editor (star, at least 80), the 8 px splitter, then the results.
    private static readonly SplitterTrack[] QueryTabOthers = [new(48, 0, false), new(300, 80, true), new(8, 0, false)];
    private static readonly SplitterTrack Results = new(320, 64, false);

    [Fact]
    public void ResultsCannotGrowPastWhatTheToolbarSplitterAndEditorMinimumLeave() =>
        Assert.Equal(780 - 48 - 80 - 8, SplitterMath.Clamp(2000, 780, Results, QueryTabOthers));

    [Fact]
    public void ADragInsideTheRoomIsKept() =>
        Assert.Equal(500, SplitterMath.Clamp(500, 780, Results, QueryTabOthers));

    [Fact]
    public void ResultsNeverShrinkBelowTheirMinimumOrTheFloor()
    {
        Assert.Equal(64, SplitterMath.Clamp(10, 780, Results, QueryTabOthers));
        Assert.Equal(48, SplitterMath.Clamp(10, 780, new SplitterTrack(320, 0, false), QueryTabOthers));
    }

    [Fact]
    public void AGridTooSmallForBothKeepsTheMinimum() =>
        Assert.Equal(64, SplitterMath.Clamp(400, 100, Results, QueryTabOthers));
}
