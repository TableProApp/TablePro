using FlaUI.Core.AutomationElements;
using FlaUI.Core.Tools;

namespace TablePro.App.UITests;

public sealed partial class ShellTests
{
    [Theory]
    [MemberData(nameof(Themes))]
    public void ResultsShowAsJsonTextAndAsATreeOfRows(string theme)
    {
        using var app = AppSession.Launch(theme);
        app.Click(app.Find("SampleCard"), () => app.TryFind("Rail_Chinook (Sample)") is not null);
        app.Click(app.FindByName("Artist", app.Find("ObjectTree")), () => app.TryFind("TableStatus") is not null);
        AppSession.WaitForText(
            app.Find("TableStatus"), value => value.StartsWith("Rows: 275", StringComparison.Ordinal));
        var grid = app.Find("ResultsGrid");
        Assert.Equal("AC/DC", app.WaitForCell(grid, 0, 1, value => value == "AC/DC"));

        app.Click(app.Find("ResultsJsonView"), () => app.TryFind("JsonText") is { IsOffscreen: false });
        var text = string.Empty;
        bool Written() =>
            (text = app.Find("JsonText").AsTextBox().Text).Contains("\"Name\": \"AC/DC\"", StringComparison.Ordinal);
        Assert.True(Retry.WhileFalse(Written, AppSession.Wait, throwOnTimeout: false).Success, text);
        Assert.Contains("\"ArtistId\": 1,", text, StringComparison.Ordinal);
        Assert.StartsWith("Rows: 275", AppSession.TextOf(app.Find("JsonRowsLine")), StringComparison.Ordinal);
        Assert.True(app.Find("CopyJson").IsEnabled);
        app.Screenshot("160-results-json-text");

        // A row's fields are made as it opens.
        app.Click(app.Find("JsonTreeMode"), () => app.TryFind("JsonTree") is { IsOffscreen: false });
        var tree = app.Find("JsonTree");
        app.FindByNamePrefix("[0]: ", tree).Patterns.ExpandCollapse.Pattern.Expand();
        Assert.Equal("Name: \"AC/DC\"", app.FindByNamePrefix("Name: ", tree).Name);
        Assert.Equal("ArtistId: 1", app.FindByNamePrefix("ArtistId: ", tree).Name);
        app.Screenshot("161-results-json-tree");

        // Data shows the grid as it was left.
        app.Click(app.Find("ResultsDataView"), () => app.TryFind("ResultsGrid") is { IsOffscreen: false });
        Assert.Equal("AC/DC", app.WaitForCell(app.Find("ResultsGrid"), 0, 1, value => value == "AC/DC"));
        Assert.True(
            Retry.WhileTrue(() => app.TryFind("JsonText") is not null, AppSession.Wait, throwOnTimeout: false).Success);
    }
}
