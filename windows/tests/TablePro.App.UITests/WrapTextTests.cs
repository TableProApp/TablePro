using FlaUI.Core.Definitions;
using FlaUI.Core.Tools;
using FlaUI.Core.WindowsAPI;

namespace TablePro.App.UITests;

public sealed partial class ShellTests
{
    private const string WrapRows =
        "SELECT 1 AS id, 'short' AS note "
        + "UNION ALL SELECT 2, 'A value long enough to need more than one line: the column starts at the width of its "
        + "first fifty characters and never past eight hundred pixels, so the rest of this sentence wraps below, and "
        + "its row grows to hold every line while the rows around it stay one line tall.' "
        + "UNION ALL SELECT 3, 'first line' || char(13) || char(10) || 'second line' "
        + "UNION ALL SELECT 4, 'short again'";

    [Theory]
    [MemberData(nameof(Themes))]
    public void WrapTextWrapsAResultsCellsFromTheViewMenuAndFromAColumnHeader(string theme)
    {
        using var app = AppSession.Launch(theme);
        app.Click(app.Find("SampleCard"), () => app.TryFind("Rail_Chinook (Sample)") is not null);
        app.FindByName("Track", app.Find("ObjectTree"));
        app.TypeInto("Query 1", WrapRows);
        app.Chord(
            () => app.Find("QueryStatus").Name.StartsWith("Rows: ", StringComparison.Ordinal),
            VirtualKeyShort.CONTROL,
            VirtualKeyShort.ENTER);
        var grid = app.Find("ResultsGrid");
        app.WaitForCell(grid, 3, 1, value => value == "short again");
        var oneLine = CellOf(grid, 0, 1).BoundingRectangle.Height;
        Assert.Equal(oneLine, CellOf(grid, 1, 1).BoundingRectangle.Height);
        Assert.Equal("first line  second line", AppSession.Cell(grid, 2, 1));

        app.Click(app.Find("ViewMenu"), () => app.TryFindMenuItem("Wrap text") is { IsEnabled: true });
        Assert.Equal(ToggleState.Off, app.FindMenuItem("Wrap text").Patterns.Toggle.Pattern.ToggleState.Value);
        app.Click(app.FindMenuItem("Wrap text"), () => CellOf(grid, 1, 1).BoundingRectangle.Height > oneLine);

        app.WaitForCell(grid, 2, 1, value => value == "first line\nsecond line");
        Assert.Equal(oneLine, CellOf(grid, 0, 1).BoundingRectangle.Height);
        Assert.True(CellOf(grid, 2, 1).BoundingRectangle.Height > oneLine);
        Assert.True(CellOf(grid, 1, 1).BoundingRectangle.Height > CellOf(grid, 2, 1).BoundingRectangle.Height);
        Assert.Equal(oneLine, CellOf(grid, 3, 1).BoundingRectangle.Height);
        Assert.Equal(CellOf(grid, 1, 1).BoundingRectangle.Bottom, CellOf(grid, 2, 1).BoundingRectangle.Top);
        app.Screenshot("185-grid-wrap-text");

        app.RightClick(HeaderElement(grid, 1), () => app.TryFindMenuItem("Wrap text") is not null);
        Assert.Equal(ToggleState.On, app.FindMenuItem("Wrap text").Patterns.Toggle.Pattern.ToggleState.Value);
        app.Screenshot("186-grid-wrap-text-header-menu");
        app.Click(app.FindMenuItem("Wrap text"), () => CellOf(grid, 1, 1).BoundingRectangle.Height == oneLine);
        Assert.Equal(oneLine, CellOf(grid, 2, 1).BoundingRectangle.Height);
        Assert.Equal("first line  second line", AppSession.Cell(grid, 2, 1));

        app.Click(app.Find("ViewMenu"), () => app.TryFindMenuItem("Wrap text") is { IsEnabled: true });
        Assert.Equal(ToggleState.Off, app.FindMenuItem("Wrap text").Patterns.Toggle.Pattern.ToggleState.Value);
        app.Click(app.FindMenuItem("Wrap text"), () => CellOf(grid, 1, 1).BoundingRectangle.Height > oneLine);
        Assert.True(Retry.WhileFalse(
            () => CellOf(grid, 2, 1).BoundingRectangle.Height > oneLine, AppSession.Wait, throwOnTimeout: false).Success);
    }
}
