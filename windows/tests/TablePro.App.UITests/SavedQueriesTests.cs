using FlaUI.Core.AutomationElements;
using FlaUI.Core.Definitions;
using FlaUI.Core.Tools;
using FlaUI.Core.WindowsAPI;

namespace TablePro.App.UITests;

public sealed partial class ShellTests
{
    private const string FiveTracks = "SELECT Name FROM Track LIMIT 5;";

    [Theory]
    [MemberData(nameof(Themes))]
    public void AQueryIsSavedIntoAFolderAndARunIsPinned(string theme)
    {
        using var app = AppSession.Launch(theme);

        app.Click(app.Find("SampleCard"), () => app.TryFind("Rail_Chinook (Sample)") is not null);
        app.FindByName("Track", app.Find("ObjectTree"));
        app.TypeInto("Query 1", FiveTracks);
        app.Chord(
            () => app.Find("QueryStatus").Name.StartsWith("Rows: 5", StringComparison.Ordinal),
            VirtualKeyShort.CONTROL,
            VirtualKeyShort.ENTER);

        // The name starts as the query's first line.
        app.Click(app.Find("QueryMenu"), () => app.TryFindMenuItem("Save query...") is { IsEnabled: true });
        app.Click(app.FindMenuItem("Save query..."), () => app.TryFind("SavedQueryNameBox") is not null);
        var name = app.Find("SavedQueryNameBox").AsTextBox();
        Assert.Equal(FiveTracks, name.Text);
        name.Text = "Five tracks";
        app.Screenshot("71-save-query-dialog");
        app.PressDialogButton();
        Assert.True(Retry.WhileTrue(() => app.TryFind("SavedQueryNameBox") is not null, AppSession.Wait, throwOnTimeout: false).Success);

        app.Click(app.Find("ViewMenu"), () => app.TryFindMenuItem("Show saved queries") is not null);
        app.Click(app.FindMenuItem("Show saved queries"), () => app.TryFind("SavedQueriesTree") is { IsOffscreen: false });
        var tree = app.Find("SavedQueriesTree");
        AutomationElement Saved() => app.FindByNamePrefix("Five tracks,", tree);
        Assert.Equal($"Five tracks, {FiveTracks}", Saved().Name);
        app.Screenshot("70-saved-queries");

        // A blank query tab takes the saved text.
        bool Open() => app.Find("Tabs").FindFirstDescendant(condition => condition.ByName("Query 2")) is not null;
        app.Chord(Open, VirtualKeyShort.CONTROL, VirtualKeyShort.KEY_T);
        InsertSaved(app, Saved, "Query 2");
        Assert.Equal(FiveTracks, AppSession.EditorText(app.FindEditor("Query 2")).TrimEnd('\r', '\n'));

        app.Find("NewSavedFolderButton").AsButton().Invoke();
        var folderName = app.Find("NameDialogBox").AsTextBox();
        Assert.Equal("New folder", folderName.Text);
        folderName.Text = "Reports";
        app.PressDialogButton();
        app.FindByName("Reports", tree);

        app.RightClick(Saved(), () => app.TryFindMenuItem("Move to") is not null);
        app.OpenSubmenu("Move to", "Reports").Patterns.Invoke.Pattern.Invoke();

        // The folder opens to show the query moved into it, and closing the folder hides it.
        AutomationElement Folder() => app.FindByName("Reports", tree);
        bool Shown() => tree.FindFirstDescendant(condition =>
            condition.ByName($"Five tracks, {FiveTracks}")) is { IsOffscreen: false };
        Assert.True(Retry.WhileFalse(
            () => Folder().Patterns.ExpandCollapse.Pattern.ExpandCollapseState.Value == ExpandCollapseState.Expanded && Shown(),
            AppSession.Wait,
            throwOnTimeout: false).Success);
        app.Screenshot("72-saved-query-folders");
        Folder().Patterns.ExpandCollapse.Pattern.Collapse();
        Assert.True(Retry.WhileTrue(Shown, AppSession.Wait, throwOnTimeout: false).Success);
        Folder().Patterns.ExpandCollapse.Pattern.Expand();
        Assert.True(Retry.WhileFalse(Shown, AppSession.Wait, throwOnTimeout: false).Success);

        // Showing the history puts the saved queries away.
        app.Click(app.Find("ViewMenu"), () => app.TryFindMenuItem("Show query history") is not null);
        app.Click(app.FindMenuItem("Show query history"), () => app.TryFind("HistoryList") is { IsOffscreen: false });
        Assert.True(Retry.WhileFalse(
            () => app.TryFind("SavedQueriesTree") is null or { IsOffscreen: true },
            AppSession.Wait,
            throwOnTimeout: false).Success);
        var runs = app.Find("HistoryList");
        app.RightClick(app.FindByNamePrefix(FiveTracks, runs), () => app.TryFindMenuItem("Pin") is not null);
        app.FindMenuItem("Pin").Patterns.Invoke.Pattern.Invoke();
        var pinned = Retry.WhileFalse(
            () => app.FindByNamePrefix(FiveTracks, runs).Name.EndsWith(", Pinned", StringComparison.Ordinal),
            AppSession.Wait,
            throwOnTimeout: false).Success;
        Assert.True(pinned, app.FindByNamePrefix(FiveTracks, runs).Name);
        app.Screenshot("73-history-pinned");

        app.RightClick(app.FindByNamePrefix(FiveTracks, runs), () => app.TryFindMenuItem("Unpin") is not null);
        app.FindMenuItem("Unpin").Patterns.Invoke.Pattern.Invoke();
        Assert.True(Retry.WhileTrue(
            () => app.FindByNamePrefix(FiveTracks, runs).Name.EndsWith(", Pinned", StringComparison.Ordinal),
            AppSession.Wait,
            throwOnTimeout: false).Success);
    }

    // The runner's own windows can take a double-click, so it goes again until the editor holds the text.
    private static void InsertSaved(AppSession app, Func<AutomationElement> row, string tab)
    {
        for (var attempt = 0; attempt < 3; attempt++)
        {
            app.Front();
            row().DoubleClick();
            if (Retry.WhileFalse(
                    () => AppSession.EditorText(app.FindEditor(tab)).TrimEnd('\r', '\n').Length > 0,
                    TimeSpan.FromSeconds(5),
                    throwOnTimeout: false).Success)
            {
                return;
            }
        }

        throw new InvalidOperationException($"Double-clicking the saved query did not fill {tab}.");
    }
}
