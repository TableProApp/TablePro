using FlaUI.Core.AutomationElements;
using FlaUI.Core.WindowsAPI;

namespace TablePro.App.UITests;

public sealed partial class ShellTests
{
    private const string TwoSelects = "SELECT 1 AS a; SELECT 2 AS b";

    [Theory]
    [MemberData(nameof(Themes))]
    public void RunStatementRunsOnlyTheStatementAtTheCursorAndSelectsIt(string theme)
    {
        using var app = AppSession.Launch(theme);

        app.Click(app.Find("SampleCard"), () => app.TryFind("Rail_Chinook (Sample)") is not null);
        app.FindByName("Track", app.Find("ObjectTree"));
        app.TypeInto("Query 1", TwoSelects);
        app.Chord(
            () => app.Find("QueryStatus").Name.StartsWith("Rows: 1", StringComparison.Ordinal),
            VirtualKeyShort.CONTROL,
            VirtualKeyShort.SHIFT,
            VirtualKeyShort.ENTER);

        Assert.Equal("2", app.WaitForCell(app.Find("ResultsGrid"), 0, 0, value => value == "2"));
        Assert.Equal("SELECT 2 AS b", app.FindEditor("Query 1").Patterns.Text.Pattern.GetSelection()[0].GetText(-1));
        Assert.True(app.TryFind("ResultPicker") is null or { IsOffscreen: true });
        app.Screenshot("41-run-statement");
    }

    [Theory]
    [MemberData(nameof(Themes))]
    public void EveryResultSetOfARunCanBePicked(string theme)
    {
        using var app = AppSession.Launch(theme);

        app.Click(app.Find("SampleCard"), () => app.TryFind("Rail_Chinook (Sample)") is not null);
        app.FindByName("Track", app.Find("ObjectTree"));
        app.TypeInto("Query 1", TwoSelects);
        app.Chord(
            () => app.TryFind("ResultPicker") is { IsOffscreen: false },
            VirtualKeyShort.CONTROL,
            VirtualKeyShort.ENTER);
        Assert.Equal("1", app.WaitForCell(app.Find("ResultsGrid"), 0, 0, value => value == "1"));

        var picker = app.Find("ResultPicker").AsComboBox();
        picker.Select("Result 2 (1)");
        picker.Collapse();

        Assert.Equal("2", app.WaitForCell(app.Find("ResultsGrid"), 0, 0, value => value == "2"));
        app.Screenshot("42-result-picker");
    }
}
