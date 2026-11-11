using FlaUI.Core.AutomationElements;
using FlaUI.Core.Definitions;
using FlaUI.Core.Input;
using FlaUI.Core.Tools;
using FlaUI.Core.WindowsAPI;

namespace TablePro.App.UITests;

public sealed partial class ShellTests
{
    [Theory]
    [MemberData(nameof(Themes))]
    public void ATableTabKeepsEditsPendingPreviewsTheirSqlAndSavesThem(string theme)
    {
        const string Renamed = "AC/DC (edited)";
        const string Added = "TablePro Test Artist";
        using var app = AppSession.Launch(theme);

        app.Click(app.Find("SampleCard"), () => app.TryFind("Rail_Chinook (Sample)") is not null);
        app.Click(app.FindByName("Artist", app.Find("ObjectTree")), () => app.TryFind("TableStatus") is not null);
        AppSession.WaitForText(app.Find("TableStatus"), value => value.StartsWith("Rows: 275", StringComparison.Ordinal));
        var grid = app.Find("ResultsGrid");

        // F2 opens the cell with its whole value selected, and Enter keeps what was typed, pending.
        app.Click(CellOf(grid, 0, 1));
        app.Chord(() => GridEditor(grid) is not null, VirtualKeyShort.F2);
        Keyboard.Type(Renamed);
        app.Chord(() => GridEditor(grid) is null, VirtualKeyShort.RETURN);
        Assert.Equal(Renamed, app.WaitForCell(grid, 0, 1, value => value == Renamed));
        Assert.Equal("edited", ItemStatusOf(grid, 0, 1));

        // Artists 1 to 24 have albums, which a foreign key keeps; the 25th, grid row 24, has none.
        Keyboard.Type(Enumerable.Repeat(VirtualKeyShort.DOWN, 24).ToArray());
        var deleted = app.WaitForCell(grid, 24, 1, value => value.Length > 0);
        app.Chord(() => ItemStatusOf(grid, 24, 1) == "marked for deletion", VirtualKeyShort.DELETE);
        app.Screenshot("44-table-edits-pending");

        // A new row follows the page's rows and opens on the first column the server does not fill.
        app.Chord(() => GridEditor(grid) is not null, VirtualKeyShort.CONTROL, VirtualKeyShort.SHIFT, VirtualKeyShort.KEY_N);
        Keyboard.Type(Added);
        app.Chord(() => GridEditor(grid) is null, VirtualKeyShort.RETURN);
        Assert.Equal(Added, app.WaitForCell(grid, 275, 1, value => value == Added));
        Assert.Equal("new row", ItemStatusOf(grid, 275, 1));
        app.Screenshot("45-table-new-row");

        app.Chord(
            () => app.TryFind("PreviewSqlStatements") is not null,
            VirtualKeyShort.CONTROL,
            VirtualKeyShort.SHIFT,
            VirtualKeyShort.KEY_P);
        var preview = app.Find("PreviewSqlStatements").Name;
        Assert.Contains("UPDATE", preview, StringComparison.Ordinal);
        Assert.Contains("INSERT", preview, StringComparison.Ordinal);
        Assert.Contains("DELETE", preview, StringComparison.Ordinal);
        app.Screenshot("46-table-preview-sql");
        app.CloseDialog();
        Assert.True(Retry.WhileTrue(() => app.TryFind("PreviewSqlStatements") is not null, AppSession.Wait, throwOnTimeout: false).Success);

        // A save that deletes rows asks first at every Safe Mode level; the page is read again once it wrote.
        app.Chord(() => app.TryFind("PrimaryButton") is not null, VirtualKeyShort.CONTROL, VirtualKeyShort.KEY_S);
        app.PressDialogButton();
        if (Retry.WhileNull(() => app.TryFind("SaveReviewStatements"), TimeSpan.FromSeconds(3), throwOnTimeout: false).Result is not null)
        {
            app.PressDialogButton();
        }

        Assert.Equal(Renamed, app.WaitForCell(grid, 0, 1, value => value == Renamed && ItemStatusOf(grid, 0, 1).Length == 0));

        // The table holds what was saved: the new name and the new row, and not the deleted one.
        app.Chord(() => app.TryFind("SqlEditor") is { IsOffscreen: false }, VirtualKeyShort.CONTROL, VirtualKeyShort.KEY_1);
        var names = string.Join(", ", new[] { Renamed, Added, deleted }.Select(name => "'" + name.Replace("'", "''", StringComparison.Ordinal) + "'"));
        app.TypeInto("Query 1", $"SELECT COUNT(*) FROM Artist WHERE Name IN ({names});");
        app.Chord(() => app.Find("QueryStatus").Name.StartsWith("Rows: 1", StringComparison.Ordinal),
            VirtualKeyShort.CONTROL, VirtualKeyShort.ENTER);
        Assert.Equal("2", app.WaitForCell(app.Find("ResultsGrid"), 0, 0, value => value == "2"));
    }

    private static AutomationElement CellOf(AutomationElement grid, int row, int column) =>
        Retry.WhileNull(() => grid.Patterns.Grid.Pattern.GetItem(row, column), AppSession.Wait, throwOnTimeout: false).Result
            ?? throw new InvalidOperationException($"No cell ({row}, {column}) appeared.");

    // The grid lists its open editor, a TextBox, as its pane's one child.
    private static AutomationElement? GridEditor(AutomationElement grid) =>
        grid.FindFirstDescendant(condition => condition.ByControlType(ControlType.Edit));

    private static string ItemStatusOf(AutomationElement grid, int row, int column) =>
        grid.Patterns.Grid.Pattern.GetItem(row, column)?.Properties.ItemStatus.ValueOrDefault ?? string.Empty;
}
