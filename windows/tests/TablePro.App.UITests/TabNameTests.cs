using FlaUI.Core.AutomationElements;
using FlaUI.Core.Definitions;
using FlaUI.Core.Input;
using FlaUI.Core.Tools;
using FlaUI.Core.WindowsAPI;

namespace TablePro.App.UITests;

// A query tab's typed name and its automatic number, in the same class so they run one at a time with the rest.
public sealed partial class ShellTests
{
    private const string TabRenameBox = "TabRenameBox";

    [Theory]
    [MemberData(nameof(Themes))]
    public void AQueryTabIsRenamedInPlaceAndTheNameSurvivesARelaunchAndAReopen(string theme)
    {
        var folder = AppSession.NewDataFolder(theme);
        using (var app = AppSession.Relaunch(folder, theme))
        {
            app.OpenSampleFromHelp();
            app.FindByName("Track", app.Find("ObjectTree"));
            var tabs = app.Find("Tabs");

            // F2 on the tab itself, as the strip has it with one tab too; Enter keeps the name.
            PressF2On(app, WaitForTab(tabs, "Query 1"));
            var box = app.Find(TabRenameBox).AsTextBox();
            Assert.Equal("Query 1", box.Text);
            box.Text = "Monthly report";
            app.Screenshot("147-tab-renaming");
            app.Chord(() => app.TryFind(TabRenameBox) is null, VirtualKeyShort.RETURN);
            WaitForTab(tabs, "Monthly report");
            app.Screenshot("148-tab-renamed");

            // The menu, then Escape keeps the name the tab had.
            app.RightClick(Tab(tabs, "Monthly report")!, () => app.TryFindMenuItem("Rename tab") is not null);
            app.FindMenuItem("Rename tab").Patterns.Invoke.Pattern.Invoke();
            app.Find(TabRenameBox).AsTextBox().Text = "Discarded";
            app.Chord(() => app.TryFind(TabRenameBox) is null, VirtualKeyShort.ESCAPE);
            Assert.NotNull(Tab(tabs, "Monthly report"));
            Assert.Null(Tab(tabs, "Discarded"));

            // The name hides Query 1 without giving its number away.
            app.Chord(() => Tab(tabs, "Query 2") is not null, VirtualKeyShort.CONTROL, VirtualKeyShort.KEY_T);
            Assert.Null(Tab(tabs, "Query 1"));

            // An emptied name goes back to the automatic one.
            PressF2On(app, WaitForTab(tabs, "Query 2"));
            app.Find(TabRenameBox).AsTextBox().Text = "Scratch";
            app.Chord(() => app.TryFind(TabRenameBox) is null, VirtualKeyShort.RETURN);
            app.RightClick(WaitForTab(tabs, "Scratch"), () => app.TryFindMenuItem("Rename tab") is not null);
            app.FindMenuItem("Rename tab").Patterns.Invoke.Pattern.Invoke();
            app.Find(TabRenameBox).AsTextBox().Text = string.Empty;
            app.Chord(() => app.TryFind(TabRenameBox) is null, VirtualKeyShort.RETURN);
            WaitForTab(tabs, "Query 2");
            Assert.Null(Tab(tabs, "Scratch"));

            // A table tab is named for its table, so its menu offers no rename.
            app.Click(app.FindByName("Track", app.Find("ObjectTree")), () => Tab(tabs, "Track") is not null);
            app.RightClick(Tab(tabs, "Track")!, () => app.TryFindMenuItem("Move to new window") is not null);
            Assert.Null(app.TryFindMenuItem("Rename tab"));
            app.Chord(() => app.TryFindMenuItem("Move to new window") is null, VirtualKeyShort.ESCAPE);
            app.Close();
        }

        Assert.Contains(
            "\"customTitle\": \"Monthly report\"",
            File.ReadAllText(Path.Combine(folder, "session.json")),
            StringComparison.Ordinal);
        using var again = AppSession.Relaunch(folder, theme);
        var restored = again.Find("Tabs");
        var named = WaitForTab(restored, "Monthly report");
        Assert.NotNull(Tab(restored, "Query 2"));
        again.Screenshot("149-tab-name-restored");

        named.Patterns.SelectionItem.Pattern.Select();
        again.Chord(() => Tab(restored, "Monthly report") is null, VirtualKeyShort.CONTROL, VirtualKeyShort.KEY_W);
        again.Chord(
            () => Tab(restored, "Monthly report") is not null,
            VirtualKeyShort.CONTROL,
            VirtualKeyShort.SHIFT,
            VirtualKeyShort.KEY_T);
    }

    // The runner's measurement for the double-click route: with tear-out on, the strip is the window's caption.
    [Theory]
    [MemberData(nameof(Themes))]
    public void ADoubleClickRenamesAQueryTabWithOneTabOrManyInEitherWindow(string theme)
    {
        using var app = AppSession.Relaunch(AppSession.NewDataFolder(theme), theme, maximize: false);
        app.OpenSampleFromHelp();
        app.FindByName("Track", app.Find("ObjectTree"));
        var tabs = app.Find("Tabs");

        // With one tab, TabView drags the whole window from it.
        app.DoubleClick(WaitForTab(tabs, "Query 1"), () => app.TryFind(TabRenameBox) is not null);
        app.Find(TabRenameBox).AsTextBox().Text = "Only tab";
        app.Chord(() => app.TryFind(TabRenameBox) is null, VirtualKeyShort.RETURN);
        WaitForTab(tabs, "Only tab");

        // With two, the first press hands the drag to the hidden window kept for a tear-out.
        app.Chord(() => Tab(tabs, "Query 2") is not null, VirtualKeyShort.CONTROL, VirtualKeyShort.KEY_T);
        app.DoubleClick(Tab(tabs, "Query 2")!, () => app.TryFind(TabRenameBox) is not null);
        app.Screenshot("150-tab-rename-double-click");
        app.Chord(() => app.TryFind(TabRenameBox) is null, VirtualKeyShort.ESCAPE);
        Assert.NotNull(Tab(tabs, "Query 2"));

        app.Click(app.Find("FileMenu"), () => app.TryFindMenuItem("Move tab to new window") is not null);
        app.FindMenuItem("Move tab to new window").Patterns.Invoke.Pattern.Invoke();
        var torn = app.WaitForWindow(SampleWindow);
        var tornTabs = app.Find("Tabs", torn);
        app.DoubleClick(WaitForTab(tornTabs, "Query 2"), () => app.TryFind(TabRenameBox, torn) is not null, torn);
        app.Find(TabRenameBox, torn).AsTextBox().Text = "Torn";
        app.Chord(torn, () => app.TryFind(TabRenameBox, torn) is null, VirtualKeyShort.RETURN);
        WaitForTab(tornTabs, "Torn");

        app.Chord(torn, () => Tab(tornTabs, "Query 3") is not null, VirtualKeyShort.CONTROL, VirtualKeyShort.KEY_T);
        app.DoubleClick(Tab(tornTabs, "Query 3")!, () => app.TryFind(TabRenameBox, torn) is not null, torn);
        app.Screenshot("151-tab-rename-tab-window", torn);
        app.Chord(torn, () => app.TryFind(TabRenameBox, torn) is null, VirtualKeyShort.ESCAPE);
        Assert.NotNull(Tab(tornTabs, "Query 3"));
    }

    [Theory]
    [MemberData(nameof(Themes))]
    public void NewAndReopenedQueryTabsNeverRepeatANumberAcrossWindows(string theme)
    {
        using var app = AppSession.Relaunch(AppSession.NewDataFolder(theme), theme, maximize: false);
        app.OpenSampleFromHelp();
        app.FindByName("Track", app.Find("ObjectTree"));
        var tabs = app.Find("Tabs");
        int Count(string name) => tabs.FindAllDescendants(condition =>
            condition.ByControlType(ControlType.TabItem).And(condition.ByName(name))).Length;

        // Close Query 2 and let Ctrl+T take its number: the reopened one takes the next.
        app.Chord(() => Count("Query 2") == 1, VirtualKeyShort.CONTROL, VirtualKeyShort.KEY_T);
        app.Chord(() => Count("Query 2") == 0, VirtualKeyShort.CONTROL, VirtualKeyShort.KEY_W);
        app.Chord(() => Count("Query 2") == 1, VirtualKeyShort.CONTROL, VirtualKeyShort.KEY_T);
        app.Chord(() => Count("Query 3") == 1, VirtualKeyShort.CONTROL, VirtualKeyShort.SHIFT, VirtualKeyShort.KEY_T);
        Assert.Equal((1, 1, 1), (Count("Query 1"), Count("Query 2"), Count("Query 3")));
        app.Screenshot("152-tab-reopened-renumbered");

        // Query 3 holds its number in its own window, so a new tab here takes 4.
        app.Click(app.Find("FileMenu"), () => app.TryFindMenuItem("Move tab to new window") is not null);
        app.FindMenuItem("Move tab to new window").Patterns.Invoke.Pattern.Invoke();
        var torn = app.WaitForWindow(SampleWindow);
        Assert.True(Retry.WhileFalse(() => Count("Query 3") == 0, AppSession.Wait, throwOnTimeout: false).Success);
        WaitForTab(app.Find("Tabs", torn), "Query 3");
        app.Chord(() => Count("Query 4") == 1, VirtualKeyShort.CONTROL, VirtualKeyShort.KEY_T);
        Assert.Equal(0, Count("Query 3"));
        app.Screenshot("153-tab-numbers-across-windows");
    }

    // F2 reaches the focused element, which the tab's editor can take back, so the tab is focused before each try.
    private static void PressF2On(AppSession app, AutomationElement tab)
    {
        for (var attempt = 0; attempt < 3; attempt++)
        {
            app.Front();
            tab.Focus();
            Keyboard.TypeSimultaneously(VirtualKeyShort.F2);
            var opened = Retry.WhileFalse(
                () => app.TryFind(TabRenameBox) is not null,
                TimeSpan.FromSeconds(5),
                throwOnTimeout: false);
            if (opened.Success)
            {
                return;
            }
        }

        throw new InvalidOperationException("F2 on the tab opened no rename box.");
    }

    private static AutomationElement WaitForTab(AutomationElement tabs, string name) =>
        Retry.WhileNull(() => Tab(tabs, name), AppSession.Wait, throwOnTimeout: false).Result
        ?? throw new InvalidOperationException($"No tab {name} appeared.");
}
