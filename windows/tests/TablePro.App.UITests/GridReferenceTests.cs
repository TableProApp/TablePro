using FlaUI.Core.Tools;

namespace TablePro.App.UITests;

public sealed partial class ShellTests
{
    [Theory]
    [MemberData(nameof(Themes))]
    public void AForeignKeyOpensTheRowItPointsAtAndTheRowsPointingBack(string theme)
    {
        using var app = AppSession.Launch(theme);
        app.Click(app.Find("SampleCard"), () => app.TryFind("Rail_Chinook (Sample)") is not null);
        app.Click(app.FindByName("Track", app.Find("ObjectTree")), () => app.TryFind("TableStatus") is not null);
        var tracks = app.Find("ResultsGrid");
        Assert.Equal("1", app.WaitForCell(tracks, 0, 2, value => value == "1"));

        // The tab reads its keys once its first page shows, so the menu offers them a moment later.
        Assert.True(Retry.WhileFalse(
            () =>
            {
                app.RightClick(CellOf(tracks, 0, 2), () => app.TryFindMenuItem("View value...") is not null);
                if (app.TryFindMenuItem("Open referenced row") is not null)
                {
                    return true;
                }

                app.Chord(() => app.TryFindMenuItem("View value...") is null, FlaUI.Core.WindowsAPI.VirtualKeyShort.ESCAPE);
                return false;
            },
            AppSession.Wait,
            throwOnTimeout: false).Success);
        app.Screenshot("84-grid-foreign-key-menu");
        app.Click(app.FindMenuItem("Open referenced row"), () => app.TryFind("TableStatus") is { } status
            && status.Name.StartsWith("Rows: 1 ", StringComparison.Ordinal));
        var albums = app.Find("ResultsGrid");
        Assert.Equal("For Those About To Rock We Salute You", app.WaitForCell(albums, 0, 1, value => value.Length > 0));
        app.Screenshot("85-referenced-row");

        app.RightClick(CellOf(albums, 0, 0), () => app.TryFindMenuItem("Show referencing rows") is not null);
        app.Click(app.OpenSubmenu("Show referencing rows", "Track (AlbumId)"), () => app.TryFind("TableStatus") is { } status
            && status.Name.StartsWith("Rows: 10 ", StringComparison.Ordinal));
        Assert.Equal("1", app.WaitForCell(app.Find("ResultsGrid"), 0, 2, value => value == "1"));
        app.Screenshot("86-referencing-rows");
    }
}
