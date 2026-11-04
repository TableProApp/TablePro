using System.Drawing;
using System.Text.Json;
using FlaUI.Core.AutomationElements;
using FlaUI.Core.Definitions;
using FlaUI.Core.Tools;
using FlaUI.Core.WindowsAPI;

namespace TablePro.App.UITests;

// Tabs leaving the window and coming back, in the same class so they run one at a time with the rest.
public sealed partial class ShellTests
{
    private const string SampleWindow = "Chinook (Sample) - TablePro";

    [Theory]
    [MemberData(nameof(Themes))]
    public void ATabMovesToItsOwnWindowThatComesBackAndMergesBack(string theme)
    {
        var folder = AppSession.NewDataFolder(theme);
        Rectangle placed;
        using (var app = AppSession.Relaunch(folder, theme, maximize: false))
        {
            OpenTrack(app);
            var tab = Tab(app.Find("Tabs"), "Track")!;
            app.RightClick(tab, () => app.TryFindMenuItem("Move to new window") is not null);
            app.FindMenuItem("Move to new window").Patterns.Invoke.Pattern.Invoke();

            var torn = app.WaitForWindow(SampleWindow);
            var left = Retry.WhileFalse(() => Tab(app.Find("Tabs"), "Track") is null, AppSession.Wait, throwOnTimeout: false)
                .Success;
            Assert.True(left, "The tab stayed in the main window.");
            Assert.NotNull(Tab(app.Find("Tabs", torn), "Track"));
            Assert.Equal("1", app.WaitForCell(app.Find("ResultsGrid", torn), 0, 0, value => value == "1"));
            app.Screenshot("32-tab-own-window", torn);

            torn.Patterns.Window.Pattern.SetWindowVisualState(WindowVisualState.Normal);
            torn.Patterns.Transform.Pattern.Move(200, 120);
            torn.Patterns.Transform.Pattern.Resize(1000, 700);
            Retry.WhileFalse(() => torn.BoundingRectangle.Width == 1000, AppSession.Wait, throwOnTimeout: false);
            placed = torn.BoundingRectangle;
            app.Close();
        }

        using (var app = AppSession.Relaunch(folder, theme, maximize: false))
        {
            Assert.Equal("TablePro", app.Window.Title);
            // The window comes back where it stood, with its own tab.
            var torn = app.WaitForWindow(SampleWindow);
            var bounds = torn.BoundingRectangle;
            Assert.InRange(bounds.Left, placed.Left - 2, placed.Left + 2);
            Assert.InRange(bounds.Top, placed.Top - 2, placed.Top + 2);
            Assert.InRange(bounds.Width, placed.Width - 2, placed.Width + 2);
            Assert.InRange(bounds.Height, placed.Height - 2, placed.Height + 2);
            var tab = Retry.WhileNull(() => Tab(app.Find("Tabs", torn), "Track"), AppSession.Wait, throwOnTimeout: false).Result;
            Assert.NotNull(tab);
            app.FindByName("Query 1", app.Find("Tabs"));

            // Its only tab drags the window, and over the main window's strip it joins it and the window closes.
            var strip = AddTabButton(app.Find("Tabs"));
            app.Drag(torn, () => Center(tab.BoundingRectangle), () => Center(strip.BoundingRectangle),
                () => !app.HasWindow(SampleWindow));
            app.WaitForClose(SampleWindow);
            Assert.NotNull(Retry.WhileNull(() => Tab(app.Find("Tabs"), "Track"), AppSession.Wait, throwOnTimeout: false).Result);
            app.Screenshot("33-tab-merged-back");
        }

    }

    [Theory]
    [MemberData(nameof(Themes))]
    public void ADraggedTabTearsOutAndItsWindowClosesWithItsLastTab(string theme)
    {
        using var app = AppSession.Relaunch(AppSession.NewDataFolder(theme), theme, maximize: false);
        OpenTrack(app);
        var tab = Tab(app.Find("Tabs"), "Track")!;
        app.Drag(app.Window, () => Center(tab.BoundingRectangle), () =>
        {
            var start = Center(tab.BoundingRectangle);
            return new Point(start.X + 40, start.Y + 300);
        }, () => app.HasWindow(SampleWindow));
        var torn = app.WaitForWindow(SampleWindow);
        Assert.NotNull(Retry.WhileNull(() => Tab(app.Find("Tabs", torn), "Track"), AppSession.Wait, throwOnTimeout: false).Result);
        Assert.Null(Tab(app.Find("Tabs"), "Track"));
        app.Screenshot("34-tab-torn-out", screen: true);

        app.Chord(torn, () => !app.HasWindow(SampleWindow), VirtualKeyShort.CONTROL, VirtualKeyShort.KEY_W);
        app.WaitForClose(SampleWindow);
        app.FindByName("Query 1", app.Find("Tabs"));
    }

    [Theory]
    [MemberData(nameof(Themes))]
    public void ATabCanMergeAndTearOutAgainDuringOneDrag(string theme)
    {
        using var app = AppSession.Relaunch(AppSession.NewDataFolder(theme), theme, maximize: false);
        OpenTrack(app);
        app.Click(app.Find("FileMenu"), () => app.TryFindMenuItem("Move tab to new window") is not null);
        app.FindMenuItem("Move tab to new window").Patterns.Invoke.Pattern.Invoke();
        var child = app.WaitForWindow(SampleWindow);
        var tab = Tab(app.Find("Tabs", child), "Track")!;
        var strip = AddTabButton(app.Find("Tabs"));
        var merged = false;
        app.DragThrough(child, () => Center(tab.BoundingRectangle), () => Center(strip.BoundingRectangle),
            () => merged = Tab(app.Find("Tabs"), "Track") is not null,
            () =>
            {
                var middle = Center(strip.BoundingRectangle);
                return new Point(middle.X + 40, middle.Y + 300);
            },
            () => merged && child.IsAvailable && Tab(app.Find("Tabs"), "Track") is null
                && Tab(app.Find("Tabs", child), "Track") is not null);
        Assert.True(child.IsAvailable);
        app.Screenshot("35-tab-retorn", screen: true);
    }

    [Theory]
    [MemberData(nameof(Themes))]
    public void DuplicateTableTabsRestoreAndReopenWithTheirOwnPages(string theme)
    {
        var folder = AppSession.NewDataFolder(theme);
        var database = AppSession.SampleDatabase(folder);
        var state = new
        {
            connections = new[]
            {
                new
                {
                    filePath = database,
                    name = "Paging",
                    engineId = "sqlite",
                    selectedTab = 1,
                    tabs = new[]
                    {
                        new { kind = "Table", title = "Track", table = "Track", pageSize = 100, offset = 0 },
                        new { kind = "Table", title = "Track", table = "Track", pageSize = 20, offset = 40 },
                    },
                },
            },
            front = 0,
        };
        // Merging windows can save two tabs for the same table with different pages.
        File.WriteAllText(Path.Combine(folder, "session.json"), JsonSerializer.Serialize(state));
        using var app = AppSession.Relaunch(folder, theme);
        int Count() => app.Find("Tabs").FindAllDescendants(condition =>
            condition.ByControlType(ControlType.TabItem).And(condition.ByName("Track"))).Length;
        Assert.True(Retry.WhileFalse(() => Count() == 2, AppSession.Wait, throwOnTimeout: false).Success);
        AppSession.WaitForText(app.Find("TableStatus"), text => text.StartsWith("41-60 of", StringComparison.Ordinal));
        app.Chord(() => Count() == 1, VirtualKeyShort.CONTROL, VirtualKeyShort.KEY_W);
        AppSession.WaitForText(app.Find("TableStatus"), text => text.StartsWith("1-100 of", StringComparison.Ordinal));
        app.Chord(() => Count() == 2, VirtualKeyShort.CONTROL, VirtualKeyShort.SHIFT, VirtualKeyShort.KEY_T);
        AppSession.WaitForText(app.Find("TableStatus"), text => text.StartsWith("41-60 of", StringComparison.Ordinal));
        Assert.Equal("20 rows", app.Find("PageSizeButton").Name);
    }

    [Theory]
    [MemberData(nameof(Themes))]
    public void ClosingATabWindowOrExitingAsksBeforeRollingBack(string theme)
    {
        using var app = AppSession.Launch(theme);
        app.Click(app.Find("SampleCard"), () => app.TryFind("Rail_Chinook (Sample)") is not null);
        app.FindByName("Track", app.Find("ObjectTree"));
        app.TypeInto("Query 1", "BEGIN; UPDATE Track SET Name = 'Pending' WHERE TrackId = 1;");
        app.Chord(() => app.TryFind("CommitButton") is { IsOffscreen: false }, VirtualKeyShort.CONTROL, VirtualKeyShort.ENTER);
        app.Click(app.Find("FileMenu"), () => app.TryFindMenuItem("Move tab to new window") is not null);
        app.FindMenuItem("Move tab to new window").Patterns.Invoke.Pattern.Invoke();
        var torn = app.WaitForWindow(SampleWindow);

        app.Chord(torn, () => app.TryFind("PrimaryButton", torn) is not null, VirtualKeyShort.ALT, VirtualKeyShort.F4);
        app.Find("CloseButton", torn).AsButton().Invoke();
        Assert.True(app.HasWindow(SampleWindow));
        Assert.True(app.Find("CommitButton", torn).IsEnabled);

        // Closing the primary includes held transactions in its tab windows.
        app.Chord(() => app.TryFind("PrimaryButton", torn) is not null, VirtualKeyShort.ALT, VirtualKeyShort.F4);
        app.Find("CloseButton", torn).AsButton().Invoke();
        Assert.True(app.HasWindow(SampleWindow));
        Assert.True(app.Find("CommitButton", torn).IsEnabled);

        app.Chord(torn, () => app.TryFind("PrimaryButton", torn) is not null, VirtualKeyShort.ALT, VirtualKeyShort.F4);
        app.Screenshot("35-window-close-transaction", torn);
        app.Find("PrimaryButton", torn).AsButton().Invoke();
        app.WaitForClose(SampleWindow);
        app.Chord(() => app.TryFind("SqlEditor") is not null, VirtualKeyShort.CONTROL, VirtualKeyShort.KEY_T);
        app.TypeInto("Query 1", "SELECT COUNT(*) FROM Track WHERE TrackId = 1 AND Name = 'Pending';");
        app.Chord(() => app.Find("QueryStatus").Name.StartsWith("Rows: 1", StringComparison.Ordinal),
            VirtualKeyShort.CONTROL, VirtualKeyShort.ENTER);
        Assert.Equal("0", app.WaitForCell(app.Find("ResultsGrid"), 0, 0, value => value == "0"));
    }

    [Theory]
    [MemberData(nameof(Themes))]
    public void CancellingCloseSelectsTheConnectionWhoseTransactionWasShown(string theme)
    {
        var folder = AppSession.NewDataFolder(theme);
        var first = AppSession.SampleDatabase(folder);
        var second = Path.Combine(folder, "second.sqlite");
        File.Copy(first, second);
        var state = new
        {
            connections = new[]
            {
                new { filePath = first, name = "First", engineId = "sqlite",
                    tabs = new[] { new { kind = "Query", title = "Query 1", sql = "BEGIN" } } },
                new { filePath = second, name = "Second", engineId = "sqlite",
                    tabs = new[] { new { kind = "Query", title = "Query 1", sql = "SELECT 2" } } },
            },
            front = 0,
        };
        File.WriteAllText(Path.Combine(folder, "session.json"), JsonSerializer.Serialize(state));
        using var app = AppSession.Relaunch(folder, theme);
        app.Find("SqlEditor");
        app.Chord(() => app.TryFind("CommitButton") is { IsOffscreen: false }, VirtualKeyShort.CONTROL, VirtualKeyShort.ENTER);
        app.Find("Rail_Second").Patterns.SelectionItem.Pattern.Select();
        Assert.True(Retry.WhileFalse(() => AppSession.EditorText(app.Find("SqlEditor")) == "SELECT 2",
            AppSession.Wait, throwOnTimeout: false).Success);
        app.Chord(() => app.TryFind("PrimaryButton") is not null, VirtualKeyShort.ALT, VirtualKeyShort.F4);
        app.CloseDialog();
        Assert.True(app.Find("Rail_First").Patterns.SelectionItem.Pattern.IsSelected.Value);
        app.Find("Rail_Second").Patterns.SelectionItem.Pattern.Select();
        Assert.Equal("SELECT 2", AppSession.EditorText(app.Find("SqlEditor")));
        app.Find("Rail_First").Patterns.SelectionItem.Pattern.Select();
        app.Find("RollBackButton").AsButton().Invoke();
        app.PressDialogButton();
    }

    private static void OpenTrack(AppSession app)
    {
        app.Click(app.Find("SampleCard"), () => app.TryFind("Rail_Chinook (Sample)") is not null);
        var track = app.FindByName("Track", app.Find("ObjectTree"));
        app.Click(track, () => app.TryFind("TableStatus") is not null);
        AppSession.WaitForText(app.Find("TableStatus"), text => text.Contains(" of 3,503", StringComparison.Ordinal));
    }

    private static AutomationElement? Tab(AutomationElement tabs, string name) =>
        tabs.FindFirstDescendant(condition => condition.ByControlType(ControlType.TabItem).And(condition.ByName(name)));

    // TabView names its add button for screen readers; the template part is AddButton.
    private static AutomationElement AddTabButton(AutomationElement tabs) =>
        tabs.FindFirstDescendant(condition => condition.ByAutomationId("AddButton"))
        ?? tabs.FindFirstDescendant(condition => condition.ByControlType(ControlType.Button).And(condition.ByName("Add New Tab")))
        ?? throw new InvalidOperationException("The tab strip has no add button.");

    // The middle of the bounds, since a point another window covers has no clickable point.
    private static Point Center(Rectangle bounds) => new(bounds.Left + (bounds.Width / 2), bounds.Top + (bounds.Height / 2));
}
