using TablePro.Core.JoinBuilder;

namespace TablePro.Core.Tests.JoinBuilder;

public sealed class JoinBuilderLayoutTests
{
    [Fact]
    public void AWideTabKeepsTheFullSideColumns() =>
        Assert.Equal((JoinBuilderLayout.ListWidth, JoinBuilderLayout.DetailsWidth), JoinBuilderLayout.Columns(1300));

    [Theory]
    [InlineData(700)]
    [InlineData(820)]
    [InlineData(860)]
    public void ANarrowTabShrinksTheSideColumnsSoTheCanvasKeepsItsMinimum(double width)
    {
        var (list, details) = JoinBuilderLayout.Columns(width);

        Assert.True(width - list - details >= JoinBuilderLayout.CanvasMinimum - 0.001, $"canvas got {width - list - details}");
        Assert.InRange(list, JoinBuilderLayout.ListMinimum, JoinBuilderLayout.ListWidth);
        Assert.InRange(details, JoinBuilderLayout.DetailsMinimum, JoinBuilderLayout.DetailsWidth);
    }

    [Fact]
    public void AVeryNarrowTabStopsTheSideColumnsAtTheirMinimums()
    {
        var (list, details) = JoinBuilderLayout.Columns(500);

        Assert.Equal(JoinBuilderLayout.ListMinimum, list);
        Assert.Equal(JoinBuilderLayout.DetailsMinimum, details);
    }

    [Fact]
    public void TheLayoutChangesSmoothlyAcrossTheThreshold()
    {
        var atThreshold = JoinBuilderLayout.Columns(JoinBuilderLayout.CanvasMinimum + JoinBuilderLayout.ListWidth + JoinBuilderLayout.DetailsWidth);
        var justBelow = JoinBuilderLayout.Columns(JoinBuilderLayout.CanvasMinimum + JoinBuilderLayout.ListWidth + JoinBuilderLayout.DetailsWidth - 1);

        Assert.True(atThreshold.List - justBelow.List < 1 && atThreshold.Details - justBelow.Details < 1);
    }
}
