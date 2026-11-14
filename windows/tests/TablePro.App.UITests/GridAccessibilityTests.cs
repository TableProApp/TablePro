using FlaUI.Core.WindowsAPI;

namespace TablePro.App.UITests;

public sealed partial class ShellTests
{
    [Theory]
    [MemberData(nameof(Themes))]
    public void AGridCellNamesItsRowAndColumnHeadersAndARowHeaderSelectsItsRow(string theme)
    {
        using var app = AppSession.Launch(theme);
        app.Click(app.Find("SampleCard"), () => app.TryFind("Rail_Chinook (Sample)") is not null);
        app.FindByName("Track", app.Find("ObjectTree"));
        app.TypeInto("Query 1", "SELECT TrackId, Name FROM Track ORDER BY TrackId");
        app.Chord(
            () => app.Find("QueryStatus").Name.StartsWith("Rows: ", StringComparison.Ordinal),
            VirtualKeyShort.CONTROL,
            VirtualKeyShort.ENTER);
        var grid = app.Find("ResultsGrid");
        Assert.Equal("1", app.WaitForCell(grid, 0, 0, value => value == "1"));
        var cell = CellOf(grid, 0, 1);
        var column = Assert.Single(cell.Patterns.TableItem.Pattern.ColumnHeaderItems.Value);
        var row = Assert.Single(cell.Patterns.TableItem.Pattern.RowHeaderItems.Value);
        Assert.Equal("Name", column.Name);
        Assert.Equal("1", row.Name);
        Assert.Equal("DataGridColumnHeader", column.Properties.ClassName.Value);
        Assert.Equal("DataGridRowHeader", row.Properties.ClassName.Value);
        row.Patterns.Invoke.Pattern.Invoke();
        Assert.Equal(2, grid.Patterns.Selection.Pattern.Selection.Value.Length);
        app.Screenshot("87-grid-row-headers");
    }
}
