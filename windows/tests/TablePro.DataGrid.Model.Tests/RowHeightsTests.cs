namespace TablePro.DataGrid.Model.Tests;

// The rows of a grid that wraps its cells: one pitch each until measured, then a line height more per extra line.
public sealed class RowHeightsTests
{
    private const double Pitch = 32;
    private const double Line = 19;

    [Fact]
    public void RowsNotYetMeasuredAreOnePitchEachAsInAGridThatDoesNotWrap()
    {
        var heights = new RowHeights(1_000, Pitch, Line);

        Assert.Equal(32_000, heights.Total);
        for (var row = 0; row <= 1_000; row += 137)
        {
            Assert.Equal(row * Pitch, heights.Top(row));
        }
        Assert.Equal(Pitch, heights.HeightOf(999));
        Assert.Equal(1, heights.LinesOf(999));
        Assert.False(heights.IsMeasured(999));
        Assert.Equal(0, heights.RowAt(0));
        Assert.Equal(0, heights.RowAt(31.9));
        Assert.Equal(1, heights.RowAt(32));
        Assert.Equal(999, heights.RowAt(31_999));
    }

    [Fact]
    public void AMeasuredRowIsOneLineHeightTallerPerExtraLineAndPushesTheRowsBelowIt()
    {
        var heights = new RowHeights(1_000, Pitch, Line);

        Assert.Equal(2 * Line, heights.Set(3, 3));
        Assert.Equal(0, heights.Set(4, 1));

        Assert.True(heights.IsMeasured(3));
        Assert.True(heights.IsMeasured(4));
        Assert.Equal(3, heights.LinesOf(3));
        Assert.Equal(Pitch + (2 * Line), heights.HeightOf(3));
        Assert.Equal(3 * Pitch, heights.Top(3));
        Assert.Equal((4 * Pitch) + (2 * Line), heights.Top(4));
        Assert.Equal((1_000 * Pitch) + (2 * Line), heights.Total);
        Assert.Equal(heights.Total, heights.Top(1_000));
    }

    [Fact]
    public void APointFallsInTheRowWhoseSpanHoldsIt()
    {
        var heights = new RowHeights(1_000, Pitch, Line);
        heights.Set(3, 3);

        Assert.Equal(2, heights.RowAt(95.9));
        Assert.Equal(3, heights.RowAt(96));
        Assert.Equal(3, heights.RowAt(96 + 69.9));
        Assert.Equal(4, heights.RowAt(96 + 70));
        Assert.Equal(0, heights.RowAt(-50));
        Assert.Equal(999, heights.RowAt(1e9));
    }

    [Fact]
    public void TopsAndPointsAgreeAcrossTheSumsEveryRowIsIn()
    {
        var heights = new RowHeights(5_000, Pitch, Line);
        var random = new Random(7);
        var lines = new int[5_000];
        Array.Fill(lines, 1);
        for (var change = 0; change < 2_000; change++)
        {
            var row = random.Next(5_000);
            lines[row] = random.Next(1, 11);
            heights.Set(row, lines[row]);
        }

        var top = 0.0;
        for (var row = 0; row < 5_000; row++)
        {
            Assert.Equal(top, heights.Top(row));
            Assert.Equal(row, heights.RowAt(top));
            Assert.Equal(row, heights.RowAt(top + heights.HeightOf(row) - 0.5));
            top += Pitch + ((lines[row] - 1) * Line);
        }
        Assert.Equal(top, heights.Total);
    }

    [Fact]
    public void ARowMeasuredAgainGivesBackTheDifference()
    {
        var heights = new RowHeights(600, Pitch, Line);
        heights.Set(300, 6);
        var below = heights.Top(500);

        Assert.Equal(-4 * Line, heights.Set(300, 2));

        Assert.Equal(below - (4 * Line), heights.Top(500));
        Assert.Equal((600 * Pitch) + Line, heights.Total);
    }

    [Fact]
    public void NoRowShowsMoreThanTenLines()
    {
        var heights = new RowHeights(10, Pitch, Line);

        Assert.Equal(10, RowHeights.MaximumLines);
        Assert.Equal(9 * Line, heights.Set(0, 400));
        Assert.Equal(10, heights.LinesOf(0));
        Assert.Equal(0, heights.Set(1, 0));
        Assert.Equal(1, heights.LinesOf(1));
        Assert.Throws<ArgumentOutOfRangeException>(() => heights.Set(10, 2));
    }

    [Fact]
    public void RowsThatArriveStartAtOneLineBelowTheRowsHeld()
    {
        var heights = new RowHeights(300, Pitch, Line);
        heights.Set(299, 4);

        heights.Grow(1_000);
        heights.Grow(500);

        Assert.Equal(1_000, heights.Count);
        Assert.Equal(4, heights.LinesOf(299));
        Assert.False(heights.IsMeasured(300));
        Assert.Equal((300 * Pitch) + (3 * Line), heights.Top(300));
        Assert.Equal((1_000 * Pitch) + (3 * Line), heights.Total);
        Assert.Equal(999, heights.RowAt(heights.Total - 1));
        Assert.Equal(Line, heights.Set(999, 2));
    }

    [Fact]
    public void AResetMakesEveryRowOneLineAgain()
    {
        var heights = new RowHeights(1_000, Pitch, Line);
        heights.Set(10, 5);
        heights.Set(700, 10);
        _ = heights.Top(900);

        heights.Reset();

        Assert.Equal(32_000, heights.Total);
        Assert.False(heights.IsMeasured(10));
        Assert.Equal(900 * Pitch, heights.Top(900));
        Assert.Equal(700, heights.RowAt(700 * Pitch));
    }

    [Fact]
    public void AMillionRowsAnswerFromTheirSums()
    {
        var heights = new RowHeights(1_000_000, Pitch, Line);
        for (var row = 0; row < 1_000_000; row += 1_000)
        {
            heights.Set(row, 10);
        }

        Assert.Equal((1_000_000 * Pitch) + (1_000 * 9 * Line), heights.Total);
        Assert.Equal((999_999 * Pitch) + (1_000 * 9 * Line), heights.Top(999_999));
        Assert.Equal(999_999, heights.RowAt(heights.Total - 1));
        Assert.Equal(500_000, heights.RowAt(heights.Top(500_000) + 100));
        Assert.Equal(500_001, heights.RowAt(heights.Top(500_001)));
    }

    [Fact]
    public void AnEmptyGridHasNoHeight()
    {
        var heights = new RowHeights(0, Pitch, Line);

        Assert.Equal(0, heights.Total);
        Assert.Equal(0, heights.Top(0));
        Assert.Equal(0, heights.RowAt(100));
        Assert.Equal(Pitch, heights.HeightOf(0));
    }

    // 320 px hold ten rows of one line, or the tall row and four more.
    [Fact]
    public void APageIsTheRowsThatFitFromTheFocusedRowLessOne()
    {
        var heights = new RowHeights(100, Pitch, Line);

        Assert.Equal(9, GridNavigation.PageRows(heights, 20, 320, down: true));
        Assert.Equal(9, GridNavigation.PageRows(heights, 20, 320, down: false));

        heights.Set(22, 8);

        Assert.Equal(4, GridNavigation.PageRows(heights, 20, 320, down: true));
        Assert.Equal(9, GridNavigation.PageRows(heights, 20, 320, down: false));
        Assert.Equal(4, GridNavigation.PageRows(heights, 24, 320, down: false));
        Assert.Equal(1, GridNavigation.PageRows(heights, 22, 100, down: true));
        Assert.Equal(1, GridNavigation.PageRows(heights, 99, 320, down: true));
        Assert.Equal(1, GridNavigation.PageRows(heights, 0, 320, down: false));
    }
}
