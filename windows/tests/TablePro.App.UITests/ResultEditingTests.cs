using FlaUI.Core.Input;
using FlaUI.Core.Tools;
using FlaUI.Core.WindowsAPI;

namespace TablePro.App.UITests;

public sealed partial class ShellTests
{
    [Theory]
    [MemberData(nameof(Themes))]
    public void AQueryResultOfOneKeyedTableEditsAndRunsAgainOnceSaved(string theme)
    {
        const string Renamed = "AC/DC (from a query)";
        using var app = AppSession.Launch(theme);

        app.OpenSampleFromHelp();
        app.FindByName("Artist", app.Find("ObjectTree"));
        app.TypeInto("Query 1", "SELECT ArtistId, Name FROM Artist");
        app.Chord(
            () => AppSession.TextOf(app.Find("QueryStatus")).StartsWith("Rows: 275", StringComparison.Ordinal),
            VirtualKeyShort.CONTROL,
            VirtualKeyShort.ENTER);
        var grid = app.Find("ResultsGrid");
        Assert.Equal("AC/DC", app.WaitForCell(grid, 0, 1, value => value == "AC/DC"));

        // Once the core has opened the result's editor, F2 edits the cell as on a table tab and Enter keeps it pending.
        app.Click(CellOf(grid, 0, 1));
        app.Chord(() => GridEditor(grid) is not null, VirtualKeyShort.F2);
        Keyboard.Type(Renamed);
        app.Chord(() => GridEditor(grid) is null, VirtualKeyShort.RETURN);
        Assert.Equal(Renamed, app.WaitForCell(grid, 0, 1, value => value == Renamed));
        Assert.Equal("edited", ItemStatusOf(grid, 0, 1));
        Assert.True(Retry.WhileFalse(
            () => app.TryFind("ResultSaveChangesButton") is { IsEnabled: true },
            AppSession.Wait,
            throwOnTimeout: false).Success);
        app.Screenshot("114-result-edit-pending");

        // Ctrl+S in the grid saves the rows, never the file; Confirm writes shows the statements first.
        app.Chord(
            () => app.TryFind("SaveReviewStatements") is not null || ItemStatusOf(grid, 0, 1).Length == 0,
            VirtualKeyShort.CONTROL,
            VirtualKeyShort.KEY_S);
        if (app.TryFind("SaveReviewStatements") is not null)
        {
            app.PressDialogButton();
        }

        // The statement runs again, so the cell holds what the table holds now, with nothing pending.
        Assert.Equal(
            Renamed,
            app.WaitForCell(grid, 0, 1, value => value == Renamed && ItemStatusOf(grid, 0, 1).Length == 0));
        Assert.False(app.Find("ResultSaveChangesButton").IsEnabled);
    }

    [Theory]
    [MemberData(nameof(Themes))]
    public void AGroupedResultSaysWhyItsRowsDoNotEdit(string theme)
    {
        const string Reason = "Grouped, distinct or computed rows can't be edited.";
        using var app = AppSession.Launch(theme);

        app.OpenSampleFromHelp();
        app.FindByName("Track", app.Find("ObjectTree"));
        app.TypeInto("Query 1", "SELECT GenreId, COUNT(*) AS Tracks FROM Track GROUP BY GenreId");
        app.Chord(
            () => AppSession.TextOf(app.Find("QueryStatus")).StartsWith("Rows: ", StringComparison.Ordinal),
            VirtualKeyShort.CONTROL,
            VirtualKeyShort.ENTER);
        var grid = app.Find("ResultsGrid");
        app.WaitForCell(grid, 0, 1, value => value.Length > 0);

        // The grid takes the edit only to refuse it, and the status says why.
        app.Click(CellOf(grid, 0, 1));
        app.Chord(() => AppSession.TextOf(app.Find("QueryStatus")) == Reason, VirtualKeyShort.F2);

        Assert.Null(GridEditor(grid));
        Assert.True(app.TryFind("ResultSaveChangesButton") is null or { IsOffscreen: true });
    }
}
