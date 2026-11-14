using FlaUI.Core.AutomationElements;
using FlaUI.Core.Tools;
using FlaUI.Core.WindowsAPI;

namespace TablePro.App.UITests;

public sealed partial class ShellTests
{
    // The sample has no trigger, so the test makes one first.
    private const string CreateTrigger =
        "CREATE TRIGGER track_renamed AFTER UPDATE OF Name ON Track BEGIN SELECT 1; END;";

    private const string CountTracks = "SELECT COUNT(*) AS tracks FROM Track;";

    [Theory]
    [MemberData(nameof(Themes))]
    public void ATriggerOpensItsDefinitionReadOnlyAndInAnEditor(string theme)
    {
        using var app = AppSession.Launch(theme);

        app.Click(app.Find("SampleCard"), () => app.TryFind("Rail_Chinook (Sample)") is not null);
        var tree = app.Find("ObjectTree");
        app.FindByName("Track", tree);
        app.TypeInto("Query 1", CreateTrigger);
        app.Chord(
            () => AppSession.TextOf(app.Find("QueryStatus")).StartsWith("Done", StringComparison.Ordinal),
            VirtualKeyShort.CONTROL,
            VirtualKeyShort.ENTER);

        // F5 reads the tree again, which now has a Triggers folder holding the one trigger.
        app.Chord(
            () => tree.FindFirstDescendant(condition => condition.ByName("Triggers, 1")) is not null,
            VirtualKeyShort.F5);
        app.FindByName("Triggers, 1", tree).Patterns.ExpandCollapse.Pattern.Expand();
        app.Click(app.FindByName("track_renamed", tree), () => app.TryFind("DefinitionText") is { IsOffscreen: false });

        var definition = app.Find("DefinitionText").AsTextBox();
        var text = string.Empty;
        Retry.WhileFalse(
            () => (text = definition.Text).Contains("CREATE TRIGGER", StringComparison.Ordinal),
            AppSession.Wait,
            throwOnTimeout: false);
        Assert.Contains("CREATE TRIGGER", text, StringComparison.Ordinal);
        Assert.Contains("track_renamed", text, StringComparison.Ordinal);
        Assert.Equal("Trigger: track_renamed", app.Find("DefinitionHeader").Name);
        Assert.True(definition.IsReadOnly);
        app.Screenshot("53-definition");

        // Open in editor puts the text in a new query tab.
        app.Find("OpenInEditorButton").AsButton().Invoke();
        Assert.Contains("CREATE TRIGGER", AppSession.EditorText(app.FindEditor("Query 2")), StringComparison.Ordinal);
    }

    [Theory]
    [MemberData(nameof(Themes))]
    public void ARunIsKeptInHistoryAndOpensAgainAndOffersExport(string theme)
    {
        using var app = AppSession.Launch(theme);

        app.Click(app.Find("SampleCard"), () => app.TryFind("Rail_Chinook (Sample)") is not null);
        app.FindByName("Track", app.Find("ObjectTree"));
        app.TypeInto("Query 1", CountTracks);
        app.Chord(
            () => AppSession.TextOf(app.Find("QueryStatus")).StartsWith("Rows: 1", StringComparison.Ordinal),
            VirtualKeyShort.CONTROL,
            VirtualKeyShort.ENTER);
        Assert.Equal("3503", app.WaitForCell(app.Find("ResultsGrid"), 0, 0, value => value == "3503"));

        // The system's save dialog is not driven: it did not take UI Automation reliably, and the core's tests write the file.
        app.Chord(
            () => app.TryFind("PrimaryButton") is not null,
            VirtualKeyShort.CONTROL,
            VirtualKeyShort.SHIFT,
            VirtualKeyShort.KEY_E);
        Assert.True(app.FindByName("CSV").AsRadioButton().IsChecked);
        app.Screenshot("55-export-dialog");
        app.CloseDialog();
        Assert.True(Retry.WhileTrue(() => app.TryFind("PrimaryButton") is not null, AppSession.Wait, throwOnTimeout: false).Success);

        app.Click(app.Find("ViewMenu"), () => app.TryFindMenuItem("Show query history") is not null);
        app.Click(app.FindMenuItem("Show query history"), () => app.TryFind("HistoryList") is { IsOffscreen: false });
        var run = app.FindByNamePrefix(CountTracks, app.Find("HistoryList"));
        app.Screenshot("54-query-history");

        // A double-click opens the run in a new query tab.
        OpenAgain(app, run, "Query 2");
        Assert.Equal(CountTracks, AppSession.EditorText(app.FindEditor("Query 2")).TrimEnd('\r', '\n'));
    }

    // The runner's own windows can take a double-click, so it goes again until the tab opens.
    private static void OpenAgain(AppSession app, AutomationElement run, string tab)
    {
        for (var attempt = 0; attempt < 3; attempt++)
        {
            app.Front();
            run.DoubleClick();
            if (Retry.WhileNull(
                    () => app.Window.FindFirstDescendant(condition =>
                        condition.ByAutomationId("SqlEditor").And(condition.ByName($"SQL editor, {tab}"))),
                    TimeSpan.FromSeconds(5),
                    throwOnTimeout: false).Result is not null)
            {
                return;
            }
        }

        throw new InvalidOperationException($"Double-clicking the run did not open {tab}.");
    }
}
