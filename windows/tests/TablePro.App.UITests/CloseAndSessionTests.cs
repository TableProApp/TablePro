using FlaUI.Core.AutomationElements;
using FlaUI.Core.Input;
using FlaUI.Core.Tools;
using FlaUI.Core.WindowsAPI;

namespace TablePro.App.UITests;

public sealed partial class ShellTests
{
    [Theory]
    [MemberData(nameof(Themes))]
    public void QueryTextComesBackAfterTheAppIsKilled(string theme)
    {
        const string Text = "SELECT 42 AS kept_after_a_kill";
        var folder = AppSession.NewDataFolder(theme);
        var session = Path.Combine(folder, "session.json");
        using (var app = AppSession.Relaunch(folder, theme))
        {
            app.Click(app.Find("SampleCard"), () => app.TryFind("Rail_Chinook (Sample)") is not null);
            app.FindByName("Track", app.Find("ObjectTree"));
            app.TypeInto("Query 1", Text);

            // On disk a moment after the typing, with the app still open.
            Assert.True(Retry.WhileFalse(() => FileHolds(session, Text), AppSession.Wait, throwOnTimeout: false).Success);
            app.Kill();
        }

        using var again = AppSession.Relaunch(folder, theme);
        var back = Retry.WhileFalse(
            () => AppSession.EditorText(again.FindEditor("Query 1")).TrimEnd('\r', '\n') == Text,
            AppSession.Wait,
            throwOnTimeout: false).Success;
        Assert.True(back);
    }

    [Theory]
    [MemberData(nameof(Themes))]
    public void APendingEditComesBackAfterTheAppIsKilledEvenWithReopenOff(string theme)
    {
        const string Renamed = "Kept after a forced end";
        var folder = AppSession.NewDataFolder(theme);
        var session = Path.Combine(folder, "session.json");
        using (var app = AppSession.Relaunch(folder, theme))
        {
            app.Click(app.Find("SampleCard"), () => app.TryFind("Rail_Chinook (Sample)") is not null);
            app.Click(app.FindByName("Artist", app.Find("ObjectTree")), () => app.TryFind("TableStatus") is not null);
            AppSession.WaitForText(
                app.Find("TableStatus"), value => value.StartsWith("Rows: 275", StringComparison.Ordinal));
            var grid = app.Find("ResultsGrid");
            app.Click(CellOf(grid, 0, 1));
            app.Chord(() => GridEditor(grid) is not null, VirtualKeyShort.F2);
            Keyboard.Type(Renamed);
            app.Chord(() => GridEditor(grid) is null, VirtualKeyShort.RETURN);
            Assert.Equal("edited", ItemStatusOf(grid, 0, 1));

            // As a forced Restart Manager close ends it: nothing runs on the way out, so the file holds the edit first.
            Assert.True(
                Retry.WhileFalse(() => FileHolds(session, Renamed), AppSession.Wait, throwOnTimeout: false).Success);
            app.Kill();
        }

        File.WriteAllText(
            Path.Combine(folder, "settings.json"),
            $$"""{ "theme": "{{theme}}", "reopenSession": false }""");
        using var again = AppSession.Relaunch(folder, theme);
        var table = again.Find("ResultsGrid");
        Assert.Equal(Renamed, again.WaitForCell(table, 0, 1, value => value == Renamed));
        Assert.Equal("edited", ItemStatusOf(table, 0, 1));
        Assert.NotNull(again.TryFind("RecoveredEditsBar"));
        again.Screenshot("63-table-edits-recovered");
        // Closing would ask about the change; the data folder goes with the test.
        again.Kill();
    }

    [Theory]
    [MemberData(nameof(Themes))]
    public void ATabWindowClosedWithItsTabsLeavesThemToReopen(string theme)
    {
        const string Text = "SELECT 7 AS from_the_closed_window";
        using var app = AppSession.Launch(theme);
        app.Click(app.Find("SampleCard"), () => app.TryFind("Rail_Chinook (Sample)") is not null);
        app.FindByName("Track", app.Find("ObjectTree"));
        var tabs = app.Find("Tabs");
        bool Open() => tabs.FindFirstDescendant(condition => condition.ByName("Query 2")) is not null;
        app.Chord(Open, VirtualKeyShort.CONTROL, VirtualKeyShort.KEY_T);
        app.TypeInto("Query 2", Text);
        app.Click(app.Find("FileMenu"), () => app.TryFindMenuItem("Move tab to new window") is not null);
        app.FindMenuItem("Move tab to new window").Patterns.Invoke.Pattern.Invoke();
        var torn = app.WaitForWindow(SampleWindow);

        app.Chord(torn, () => !app.HasWindow(SampleWindow), VirtualKeyShort.ALT, VirtualKeyShort.F4);
        app.WaitForClose(SampleWindow);
        app.Chord(Open, VirtualKeyShort.CONTROL, VirtualKeyShort.SHIFT, VirtualKeyShort.KEY_T);

        var text = string.Empty;
        Retry.WhileFalse(
            () => (text = AppSession.EditorText(app.FindEditor("Query 2"))).Contains(Text, StringComparison.Ordinal),
            AppSession.Wait,
            throwOnTimeout: false);
        Assert.Contains(Text, text, StringComparison.Ordinal);
    }

    [Theory]
    [MemberData(nameof(Themes))]
    public void ASettingChangedWhileItsFileIsHeldIsSavedOnExit(string theme)
    {
        using var app = AppSession.Launch(theme);
        var path = Path.Combine(app.DataFolder, "settings.json");
        app.Find("SettingsButton").AsButton().Invoke();
        app.Find("SettingsPage");

        // As a virus scan holds a file it reads: the app cannot replace it until it lets go.
        using (new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.None))
        {
            app.Find("ReopenSwitch").AsToggleButton().Toggle();
            Thread.Sleep(1_000);
            Assert.False(app.HasExited);
        }

        Assert.DoesNotContain("\"reopenSession\": false", File.ReadAllText(path), StringComparison.Ordinal);
        app.Find("AboutExpander");
        app.Close();
        Assert.Contains("\"reopenSession\": false", File.ReadAllText(path), StringComparison.Ordinal);
    }

    [Theory]
    [MemberData(nameof(Themes))]
    public void ClosingWhileAQueryRunsAsksFirstThenStopsIt(string theme)
    {
        using var app = AppSession.Launch(theme);
        app.Click(app.Find("SampleCard"), () => app.TryFind("Rail_Chinook (Sample)") is not null);
        app.FindByName("Track", app.Find("ObjectTree"));
        app.TypeInto("Query 1", Endless);
        app.Chord(() => app.Find("StopButton").IsEnabled, VirtualKeyShort.CONTROL, VirtualKeyShort.ENTER);

        app.Chord(() => app.TryFind("CloseRunningTabs") is not null, VirtualKeyShort.ALT, VirtualKeyShort.F4);
        Assert.Contains("Query 1", app.Find("CloseRunningTabs").Name, StringComparison.Ordinal);
        app.Screenshot("43-close-running-asked");
        app.CloseDialog();
        Assert.True(app.Find("StopButton").IsEnabled);

        app.Chord(() => app.TryFind("CloseRunningTabs") is not null, VirtualKeyShort.ALT, VirtualKeyShort.F4);
        app.PressDialogButton();
        Assert.True(Retry.WhileFalse(() => app.HasExited, AppSession.Wait, throwOnTimeout: false).Success);
    }

    // The app replaces the file as it writes, so a read can meet it mid-swap.
    private static bool FileHolds(string path, string text)
    {
        try
        {
            return File.ReadAllText(path).Contains(text, StringComparison.Ordinal);
        }
        catch (Exception exception) when (exception is IOException or UnauthorizedAccessException)
        {
            return false;
        }
    }
}
