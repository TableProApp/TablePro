using System.Drawing;
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
            app.Front();
            tab.RightClick();
            app.FindMenuItem("Move to new window").Patterns.Invoke.Pattern.Invoke();

            var torn = app.WaitForWindow(SampleWindow);
            var left = Retry.WhileFalse(() => Tab(app.Find("Tabs"), "Track") is null, AppSession.Wait, throwOnTimeout: false).Success;
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
            app.Front(torn);
            AppSession.Drag(Center(tab.BoundingRectangle), Center(strip.BoundingRectangle));
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
        var start = Center(tab.BoundingRectangle);

        app.Front();
        AppSession.Drag(start, new Point(start.X + 40, start.Y + 300));
        var torn = app.WaitForWindow(SampleWindow);
        Assert.NotNull(Retry.WhileNull(() => Tab(app.Find("Tabs", torn), "Track"), AppSession.Wait, throwOnTimeout: false).Result);
        Assert.Null(Tab(app.Find("Tabs"), "Track"));
        app.Screenshot("34-tab-torn-out", screen: true);

        app.Chord(torn, () => !app.HasWindow(SampleWindow), VirtualKeyShort.CONTROL, VirtualKeyShort.KEY_W);
        app.WaitForClose(SampleWindow);
        app.FindByName("Query 1", app.Find("Tabs"));
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
