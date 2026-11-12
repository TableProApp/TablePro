using FlaUI.Core.AutomationElements;
using FlaUI.Core.Tools;

namespace TablePro.App.UITests;

public sealed partial class ShellTests
{
    [Theory]
    [MemberData(nameof(Themes))]
    public void ATableFiltersItsRowsAndShowsItsStructure(string theme)
    {
        using var app = AppSession.Launch(theme);

        app.Click(app.Find("SampleCard"), () => app.TryFind("Rail_Chinook (Sample)") is not null);
        app.Click(app.FindByName("Track", app.Find("ObjectTree")), () => app.TryFind("TableStatus") is not null);
        var status = app.Find("TableStatus");
        Assert.Contains(
            " of 3,503 rows",
            AppSession.WaitForText(status, text => text.Contains(" of 3,503", StringComparison.Ordinal)),
            StringComparison.Ordinal);

        // The bar opens on one row, the first column and its first operator; GenreId 5 picks 12 of Track's rows.
        app.Find("FilterButton").Patterns.Toggle.Pattern.Toggle();
        app.Front();
        var column = app.Find("FilterColumn0").AsComboBox();
        column.Select("GenreId");
        column.Collapse();
        Assert.Equal("equals", app.Find("FilterOperator0").AsComboBox().SelectedItem?.Text);
        app.Find("FilterValue0").AsTextBox().Text = "5";
        var apply = app.Find("ApplyFilterButton");
        Assert.True(Retry.WhileFalse(() => apply.IsEnabled, AppSession.Wait, throwOnTimeout: false).Success);
        apply.AsButton().Invoke();
        Assert.StartsWith(
            "Rows: 12 ",
            AppSession.WaitForText(status, text => text.StartsWith("Rows: 12 ", StringComparison.Ordinal)),
            StringComparison.Ordinal);
        Assert.Equal("5", app.WaitForCell(app.Find("ResultsGrid"), 0, 4, value => value == "5"));
        app.Screenshot("50-table-filter");

        app.Find("ClearFilterButton").AsButton().Invoke();
        Assert.Contains(
            " of 3,503 rows",
            AppSession.WaitForText(status, text => text.Contains(" of 3,503", StringComparison.Ordinal)),
            StringComparison.Ordinal);

        app.Click(app.Find("TableStructureItem"), () => app.TryFind("StructureGrid") is { IsOffscreen: false });
        var grid = app.Find("StructureGrid");
        Assert.Equal("TrackId", app.WaitForCell(grid, 0, 0, value => value == "TrackId"));

        // SQLite lists a table's indexes in name order, so the album's comes first.
        app.Click(app.Find("StructureIndexesItem"), () => AppSession.Cell(grid, 0, 0) == "IFK_TrackAlbumId");
        Assert.Equal("AlbumId", app.WaitForCell(grid, 0, 1, value => value == "AlbumId"));
        app.Screenshot("51-table-structure");

        app.Click(app.Find("StructureDdlItem"), () => app.TryFind("StructureDdl") is { IsOffscreen: false });
        var ddl = string.Empty;
        Retry.WhileFalse(
            () => (ddl = app.Find("StructureDdl").AsTextBox().Text).Contains("CREATE TABLE", StringComparison.Ordinal),
            AppSession.Wait,
            throwOnTimeout: false);
        Assert.Contains("CREATE TABLE", ddl, StringComparison.Ordinal);
        Assert.True(app.Find("CopyDdlButton").IsEnabled);
        app.Screenshot("52-table-ddl");
    }
}
