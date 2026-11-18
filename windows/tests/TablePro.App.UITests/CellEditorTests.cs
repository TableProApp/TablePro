using FlaUI.Core.AutomationElements;
using FlaUI.Core.Tools;
using FlaUI.Core.WindowsAPI;

namespace TablePro.App.UITests;

public sealed partial class ShellTests
{
    // The sample has no boolean or date column, so the test makes a table with both.
    private const string CreateFlags =
        "CREATE TABLE flags (id INTEGER PRIMARY KEY, active BOOLEAN, born DATE); "
        + "INSERT INTO flags VALUES (1, 1, '2024-03-15'), (2, NULL, NULL);";

    [Theory]
    [MemberData(nameof(Themes))]
    public void ABooleanTogglesWhereItIsAndADateOpensItsCalendar(string theme)
    {
        using var app = AppSession.Launch(theme);

        app.Click(app.Find("SampleCard"), () => app.TryFind("Rail_Chinook (Sample)") is not null);
        var tree = app.Find("ObjectTree");
        app.FindByName("Track", tree);
        app.TypeInto("Query 1", CreateFlags);
        app.Chord(
            () => AppSession.TextOf(app.Find("QueryStatus")).StartsWith("Done", StringComparison.Ordinal),
            VirtualKeyShort.CONTROL,
            VirtualKeyShort.ENTER);
        // F5 reads the tree again with the folder counting the new table; a folder it closes is opened again.
        app.Chord(
            () => tree.FindFirstDescendant(condition => condition.ByName("Tables, 12")) is not null,
            VirtualKeyShort.F5);
        app.FindByName("Tables, 12", tree).Patterns.ExpandCollapse.Pattern.Expand();
        app.Click(app.FindByName("flags", tree), () => app.TryFind("TableStatus") is not null);
        AppSession.WaitForText(
            app.Find("TableStatus"),
            value => value.StartsWith("Rows: 2 ", StringComparison.Ordinal));
        var grid = app.Find("ResultsGrid");

        // F2 on a boolean writes its other value as a pending change and opens no editor.
        var stored = app.WaitForCell(grid, 0, 1, value => value.Length > 0);
        app.Click(CellOf(grid, 0, 1));
        app.Chord(() => ItemStatusOf(grid, 0, 1) == "edited", VirtualKeyShort.F2);
        Assert.Null(GridEditor(grid));
        var toggled = AppSession.Cell(grid, 0, 1);
        Assert.True(toggled is "0" or "false", toggled);

        // Enter on a NULL boolean makes it true.
        app.Click(CellOf(grid, 1, 1));
        app.Chord(() => ItemStatusOf(grid, 1, 1) == "edited", VirtualKeyShort.RETURN);
        Assert.Equal("true", app.WaitForCell(grid, 1, 1, value => value == "true"));
        Assert.Null(GridEditor(grid));
        app.Screenshot("150-cell-boolean-toggled");

        // Toggled back, the first row holds its stored value again with nothing pending.
        app.Click(CellOf(grid, 0, 1));
        app.Chord(() => ItemStatusOf(grid, 0, 1).Length == 0, VirtualKeyShort.RETURN);
        Assert.Equal(stored, app.WaitForCell(grid, 0, 1, value => value == stored));

        // A date opens a calendar instead of the TextBox; Escape leaves the value as it was.
        app.Click(CellOf(grid, 0, 2));
        app.Chord(() => app.TryFind("CellDatePicker") is not null, VirtualKeyShort.F2);
        Assert.Null(GridEditor(grid));
        Assert.NotNull(app.TryFind("CellEditAsText"));
        app.Screenshot("151-cell-date-picker");
        app.Chord(() => app.TryFind("CellDatePicker") is null, VirtualKeyShort.ESCAPE);
        Assert.Equal("2024-03-15", AppSession.Cell(grid, 0, 2));
        Assert.Equal(string.Empty, ItemStatusOf(grid, 0, 2));

        // Edit as text opens the TextBox on the cell's whole value.
        app.Chord(() => app.TryFind("CellEditAsText") is not null, VirtualKeyShort.F2);
        app.Find("CellEditAsText").AsButton().Invoke();
        var editor = Retry.WhileNull(() => GridEditor(grid), AppSession.Wait, throwOnTimeout: false).Result;
        Assert.NotNull(editor);
        Assert.Equal("2024-03-15", editor.AsTextBox().Text);
        Assert.Null(app.TryFind("CellDatePicker"));
        app.Screenshot("152-cell-edit-as-text");
        app.Chord(() => GridEditor(grid) is null, VirtualKeyShort.ESCAPE);
        Assert.Equal(string.Empty, ItemStatusOf(grid, 0, 2));
    }
}
