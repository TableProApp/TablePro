using System.Drawing;
using System.Runtime.InteropServices;
using System.Text.Json;
using System.Text.RegularExpressions;
using FlaUI.Core.AutomationElements;
using FlaUI.Core.Definitions;
using FlaUI.Core.Input;
using FlaUI.Core.Tools;
using FlaUI.Core.WindowsAPI;

namespace TablePro.App.UITests;

// The shell's later flows, in the same class so they still run one at a time.
public sealed partial class ShellTests
{
    [Theory]
    [MemberData(nameof(Themes))]
    public void TheEngineChooserListsEachFamilyAsTheMacAppDoes(string theme)
    {
        using var app = AppSession.Launch(theme);

        app.Click(app.Find("NewConnectionCard"), () => app.HasWindow("New connection"));
        var form = app.WaitForWindow("New connection");
        var grid = app.Find("EngineGrid", form);
        foreach (var family in new[] { "Relational", "Document", "Key-value", "Analytical", "Wide-column" })
        {
            app.FindByName(family, grid);
        }

        var wide = app.FindByName("Wide-column", grid);
        var cassandra = app.Find("Engine_cassandra", form);
        Assert.True(cassandra.BoundingRectangle.Top > wide.BoundingRectangle.Top);
        Assert.Null(grid.FindFirstDescendant(condition => condition.ByName("Files")));
        app.Screenshot("13-engine-families", form);
    }

    [Theory]
    [MemberData(nameof(Themes))]
    public void AnOpenConnectionShowsItsEngineAndColorOnTheRail(string theme)
    {
        var folder = AppSession.NewDataFolder(theme);
        var database = AppSession.SampleDatabase(folder);
        using var app = AppSession.Relaunch(folder, theme);

        app.Click(app.Find("NewConnectionCard"), () => app.HasWindow("New connection"));
        var form = app.WaitForWindow("New connection");
        app.Click(app.Find("Engine_sqlite", form), () => app.TryFind("FileBox", form) is not null, form);
        app.Find("FileBox", form).AsTextBox().Text = database;
        app.Find("NameBox", form).AsTextBox().Text = "Colored";
        app.Click(app.Find("AppearanceExpander", form), () => app.TryFind("ColorBox", form) is { IsOffscreen: false }, form);
        app.Find("ColorBox", form).AsComboBox().Select("Red");
        app.Find("ConnectButton", form).AsButton().Invoke();
        app.WaitForClose("New connection");

        var rail = app.Find("Rail_Colored");
        app.FindByName("Album", app.Find("ObjectTree"));
        Assert.Equal("SQLite", rail.Properties.HelpText.ValueOrDefault);
        app.Screenshot("14-rail-mark");
        app.Find("HomeItem").AsListBoxItem().Select();
        app.FindByNamePrefix("Colored,", app.Find("ConnectionTree"));
        app.Screenshot("15-home-marks");
    }

    [Theory]
    [MemberData(nameof(Themes))]
    public void TheObjectPaneResizesAndKeepsItsWidth(string theme)
    {
        var folder = AppSession.NewDataFolder(theme);
        int widened;
        using (var app = AppSession.Relaunch(folder, theme))
        {
            app.Click(app.Find("SampleCard"), () => app.TryFind("Rail_Chinook (Sample)") is not null);
            var tree = app.Find("ObjectTree");
            app.FindByName("Track", tree);
            var before = tree.BoundingRectangle.Width;
            var splitter = app.Find("ObjectsSplitter").BoundingRectangle;
            var start = new Point(splitter.Left + (splitter.Width / 2), splitter.Top + (splitter.Height / 2));

            app.Front();
            AppSession.Drag(start, new Point(start.X + 160, start.Y));
            var grew = Retry.WhileFalse(() => tree.BoundingRectangle.Width > before + 100, AppSession.Wait, throwOnTimeout: false).Success;
            Assert.True(grew, $"The pane stayed {tree.BoundingRectangle.Width} wide from {before}.");
            widened = tree.BoundingRectangle.Width;
            app.Screenshot("16-pane-resized");
            app.Close();
        }

        using var again = AppSession.Relaunch(folder, theme);
        var restored = again.Find("ObjectTree");
        again.FindByName("Track", restored);
        Assert.InRange(restored.BoundingRectangle.Width, widened - 4, widened + 4);
    }

    [Theory]
    [MemberData(nameof(Themes))]
    public void TheWindowComesBackWhereItStood(string theme)
    {
        var folder = AppSession.NewDataFolder(theme);
        Rectangle placed;
        using (var app = AppSession.Relaunch(folder, theme, maximize: false))
        {
            var window = app.Window;
            window.Patterns.Window.Pattern.SetWindowVisualState(WindowVisualState.Normal);
            window.Patterns.Transform.Pattern.Move(80, 60);
            window.Patterns.Transform.Pattern.Resize(1100, 720);
            Retry.WhileFalse(() => window.BoundingRectangle.Width == 1100, AppSession.Wait, throwOnTimeout: false);
            placed = window.BoundingRectangle;
            app.Close();
        }

        using (var app = AppSession.Relaunch(folder, theme, maximize: false))
        {
            var bounds = app.Window.BoundingRectangle;
            Assert.InRange(bounds.Left, placed.Left - 2, placed.Left + 2);
            Assert.InRange(bounds.Top, placed.Top - 2, placed.Top + 2);
            Assert.InRange(bounds.Width, placed.Width - 2, placed.Width + 2);
            Assert.InRange(bounds.Height, placed.Height - 2, placed.Height + 2);
            app.Screenshot("17-window-restored", screen: true);
            app.Window.Patterns.Window.Pattern.SetWindowVisualState(WindowVisualState.Maximized);
            // UI Automation posts SC_MAXIMIZE, so closing must wait until the window processes it.
            Assert.True(Retry.WhileFalse(
                () => app.Window.Patterns.Window.Pattern.WindowVisualState.Value == WindowVisualState.Maximized,
                AppSession.Wait,
                throwOnTimeout: false).Success);
            app.Close();
        }

        using var session = JsonDocument.Parse(File.ReadAllText(Path.Combine(folder, "session.json")));
        Assert.True(session.RootElement.GetProperty("window").GetProperty("maximized").GetBoolean());

        using var maximized = AppSession.Relaunch(folder, theme, maximize: false);
        var state = WindowVisualState.Normal;
        Retry.WhileFalse(
            () => (state = maximized.Window.Patterns.Window.Pattern.WindowVisualState.Value) == WindowVisualState.Maximized,
            AppSession.Wait,
            throwOnTimeout: false);
        Assert.Equal(WindowVisualState.Maximized, state);
    }

    [Theory]
    [MemberData(nameof(Themes))]
    public void APasswordIsAskedForWhenNoneIsSaved(string theme)
    {
        using var app = AppSession.Launch(theme);

        app.Click(app.Find("NewConnectionCard"), () => app.HasWindow("New connection"));
        var form = app.WaitForWindow("New connection");
        app.Click(app.Find("Engine_postgres", form), () => app.TryFind("HostBox", form) is not null, form);
        app.Find("HostBox", form).AsTextBox().Text = "127.0.0.1";
        app.Find("PortBox", form).AsTextBox().Text = "1";
        app.Find("UserBox", form).AsTextBox().Text = "nobody";
        app.Find("NameBox", form).AsTextBox().Text = "Asks";
        app.Find("SaveButton", form).AsButton().Invoke();
        app.WaitForClose("New connection");

        // The form saved the empty password it was given; taking it away leaves the connection with none saved.
        var target = $"TablePro/connection/{ConnectionId(app.DataFolder)}/database-password";
        Credentials.Delete(target);
        var row = app.FindByNamePrefix("Asks,", app.Find("ConnectionTree"));
        app.Front();
        row.DoubleClick();

        var box = app.Find("SecretBox");
        app.Screenshot("18-password-asked");
        app.Click(box);
        Keyboard.Type("typed");
        app.Find("SaveSecretBox").AsCheckBox().IsChecked = true;
        app.PressDialogButton();

        // A password that did not log in is not kept, so Retry asks again.
        app.Find("FailureBar");
        Assert.False(Credentials.Exists(target));
        app.Find("RetryButton").AsButton().Invoke();
        app.Find("SecretBox");
        app.CloseDialog();
        var gone = Retry.WhileFalse(() => app.TryFind("Rail_Asks") is null, AppSession.Wait, throwOnTimeout: false).Success;
        Assert.True(gone);
    }

    [Theory]
    [MemberData(nameof(Themes))]
    public void AClosedTabComesBackWithItsText(string theme)
    {
        using var app = AppSession.Launch(theme);

        app.Click(app.Find("SampleCard"), () => app.TryFind("Rail_Chinook (Sample)") is not null);
        app.FindByName("Track", app.Find("ObjectTree"));
        var tabs = app.Find("Tabs");
        bool Open() => tabs.FindFirstDescendant(condition => condition.ByName("Query 2")) is not null;
        app.Chord(Open, VirtualKeyShort.CONTROL, VirtualKeyShort.KEY_T);
        app.TypeInto("Query 2", "SELECT 42 AS answer");
        app.Chord(() => !Open(), VirtualKeyShort.CONTROL, VirtualKeyShort.KEY_W);
        app.Chord(Open, VirtualKeyShort.CONTROL, VirtualKeyShort.SHIFT, VirtualKeyShort.KEY_T);
        var text = string.Empty;
        Retry.WhileFalse(
            () => (text = AppSession.EditorText(app.FindEditor("Query 2"))).Contains("SELECT 42", StringComparison.Ordinal),
            AppSession.Wait,
            throwOnTimeout: false);
        Assert.Contains("SELECT 42 AS answer", text, StringComparison.Ordinal);
        app.Screenshot("19-tab-reopened");
    }

    [Theory]
    [MemberData(nameof(Themes))]
    public void AnOpenTransactionHasItsBarsAndRollsBack(string theme)
    {
        using var app = AppSession.Launch(theme);

        app.Click(app.Find("SampleCard"), () => app.TryFind("Rail_Chinook (Sample)") is not null);
        app.FindByName("Track", app.Find("ObjectTree"));
        app.TypeInto("Query 1", "BEGIN");
        app.Chord(() => app.TryFind("CommitButton") is not null, VirtualKeyShort.CONTROL, VirtualKeyShort.ENTER);

        // A closed InfoBar stays in the tree with its content folded away, so its buttons say whether it shows.
        Assert.True(app.Find("CommitButton").IsEnabled);
        app.Screenshot("20-transaction-open");

        app.Chord(() => app.TryFind("ShowTransactionTabButton") is not null, VirtualKeyShort.CONTROL, VirtualKeyShort.KEY_T);
        var show = app.Find("ShowTransactionTabButton");
        app.Screenshot("21-transaction-elsewhere");
        show.AsButton().Invoke();

        app.Find("RollBackButton").AsButton().Invoke();
        app.Screenshot("22-roll-back-asked");
        app.PressDialogButton();
        var gone = Retry.WhileFalse(
            () => app.TryFind("RollBackButton") is null or { IsOffscreen: true },
            AppSession.Wait,
            throwOnTimeout: false).Success;
        Assert.True(gone);
        Assert.True(app.TryFind("ShowTransactionTabButton") is null or { IsOffscreen: true });
    }

    [Theory]
    [MemberData(nameof(Themes))]
    public void ATablePagesByTheDefaultPageSizeAndCountsToItsLastPage(string theme)
    {
        using var app = AppSession.Launch(theme);

        app.Click(app.Find("SampleCard"), () => app.TryFind("Rail_Chinook (Sample)") is not null);
        var track = app.FindByName("Track", app.Find("ObjectTree"));
        app.Click(track, () => app.TryFind("NextPageButton") is { IsOffscreen: false });
        var status = app.Find("TableStatus");
        Assert.Matches(
            PagedStatus("1-1,000"),
            AppSession.WaitForText(status, text => text.Contains(" of 3,503", StringComparison.Ordinal)));
        Assert.Equal("1,000 rows", app.Find("PageSizeButton").Name);
        app.Screenshot("23-table-paged");

        app.Find("NextPageButton").AsButton().Invoke();
        Assert.Matches(
            PagedStatus("1,001-2,000"),
            AppSession.WaitForText(status, text => text.StartsWith("1,001-", StringComparison.Ordinal)));
        Assert.Equal("1001", app.WaitForCell(app.Find("ResultsGrid"), 0, 0, value => value == "1001"));

        app.Find("LastPageButton").AsButton().Invoke();
        Assert.Matches(
            PagedStatus("3,001-3,503"),
            AppSession.WaitForText(status, text => text.StartsWith("3,001-", StringComparison.Ordinal)));
        Assert.Equal("3001", app.WaitForCell(app.Find("ResultsGrid"), 0, 0, value => value == "3001"));
        Assert.False(app.Find("NextPageButton").IsEnabled);
        app.Screenshot("24-table-last-page");

        app.Find("FirstPageButton").AsButton().Invoke();
        Assert.Matches(
            PagedStatus("1-1,000"),
            AppSession.WaitForText(status, text => text.StartsWith("1-1,000 ", StringComparison.Ordinal)));
        Assert.False(app.Find("PreviousPageButton").IsEnabled);
    }

    [Theory]
    [MemberData(nameof(Themes))]
    public void ATableKeepsItsPageSizeAndGoesToAPageInsideItsCount(string theme)
    {
        var folder = AppSession.NewDataFolder(theme);
        using (var app = AppSession.Relaunch(folder, theme))
        {
            app.Click(app.Find("SampleCard"), () => app.TryFind("Rail_Chinook (Sample)") is not null);
            var track = app.FindByName("Track", app.Find("ObjectTree"));
            app.Click(track, () => app.TryFind("NextPageButton") is { IsOffscreen: false });
            var status = app.Find("TableStatus");
            AppSession.WaitForText(status, text => text.Contains(" of 3,503", StringComparison.Ordinal));

            app.Click(app.Find("PageSizeButton"), () => app.TryFindMenuItem("100 rows") is not null);
            app.Screenshot("29-page-size-menu");
            app.Click(app.FindMenuItem("100 rows"), () => status.Name.StartsWith("1-100 ", StringComparison.Ordinal));
            Assert.Matches(PagedStatus("1-100"), status.Name);
            Assert.Equal("100 rows", app.Find("PageSizeButton").Name);
            var goTo = app.Find("GoToPageButton");
            Assert.Equal("Page 1 of 36", AppSession.WaitForText(goTo, text => text == "Page 1 of 36"));

            app.Click(goTo, () => app.TryFind("GoToPageBox") is not null);
            var box = app.Find("GoToPageBox");
            box.Patterns.RangeValue.Pattern.SetValue(3);
            app.Screenshot("30-go-to-page");
            app.Find("GoToPageGo").AsButton().Invoke();
            Assert.Matches(
                PagedStatus("201-300"),
                AppSession.WaitForText(status, text => text.StartsWith("201-", StringComparison.Ordinal)));
            Assert.Equal("201", app.WaitForCell(app.Find("ResultsGrid"), 0, 0, value => value == "201"));

            // The count bounds the page asked for: one past the last goes to the last.
            app.Click(app.Find("GoToPageButton"), () => app.TryFind("GoToPageBox") is not null);
            app.Find("GoToPageBox").Patterns.RangeValue.Pattern.SetValue(99);
            Assert.Equal(36, app.Find("GoToPageBox").Patterns.RangeValue.Pattern.Value.Value);
            app.Find("GoToPageGo").AsButton().Invoke();
            Assert.Matches(
                PagedStatus("3,501-3,503"),
                AppSession.WaitForText(status, text => text.StartsWith("3,501-", StringComparison.Ordinal)));
            app.Close();
        }

        // The tab comes back with the size it was given and the page it showed.
        using var again = AppSession.Relaunch(folder, theme);
        var restored = again.Find("TableStatus");
        Assert.Matches(
            PagedStatus("3,501-3,503"),
            AppSession.WaitForText(restored, text => text.StartsWith("3,501-", StringComparison.Ordinal)));
        Assert.Equal("100 rows", again.Find("PageSizeButton").Name);
        again.Screenshot("31-page-restored");
    }

    [Theory]
    [MemberData(nameof(Themes))]
    public void TheConnectionsPageRenamesTagsDropsAndSelects(string theme)
    {
        using var app = AppSession.Launch(theme);

        app.Click(app.Find("SampleCard"), () => app.TryFind("Rail_Chinook (Sample)") is not null);
        app.FindByName("Track", app.Find("ObjectTree"));
        app.Find("HomeItem").AsListBoxItem().Select();
        var tree = app.Find("ConnectionTree");

        app.Find("NewGroupButton").AsButton().Invoke();
        app.Find("NameDialogBox").AsTextBox().Text = "Work";
        app.PressDialogButton();
        app.FindByName("Work", tree);

        app.Click(app.FindByNamePrefix("Chinook (Sample),", tree));
        app.Chord(() => app.TryFind("RenameBox") is not null, VirtualKeyShort.F2);
        app.Find("RenameBox").AsTextBox().Text = "Music";
        app.Screenshot("25-home-renaming");
        app.Chord(() => app.TryFind("RenameBox") is null, VirtualKeyShort.RETURN);
        var music = app.FindByNamePrefix("Music,", tree);

        app.Front();
        music.RightClick();
        app.OpenSubmenu("Tags", "New tag...").Patterns.Invoke.Pattern.Invoke();
        app.Find("NameDialogBox").AsTextBox().Text = "demo";
        app.PressDialogButton();
        var tagged = Retry.WhileFalse(
            () => app.FindByNamePrefix("Music,", tree).Name.EndsWith("demo", StringComparison.Ordinal),
            AppSession.Wait,
            throwOnTimeout: false).Success;
        Assert.True(tagged, app.FindByNamePrefix("Music,", tree).Name);
        app.Screenshot("26-home-tagged");

        var group = GroupId(app.DataFolder);
        app.Drag(
            () => app.FindByNamePrefix("Music,", tree),
            () => app.FindByName("Work", tree),
            () => Regex.IsMatch(File.ReadAllText(AppSession.LibraryFile(app.DataFolder)), $"\"group_id\"\\s*:\\s*\"{group}\""));
        app.FindByNamePrefix("Music,", tree);
        // The group the row went into opens, so the row shows there as well as under Recent.
        AutomationElement[] Music() =>
            tree.FindAllDescendants(condition => condition.ByName("Music, SQLite", PropertyConditionFlags.MatchSubstring));
        var shown = Retry.WhileFalse(() => Music().Length == 2, AppSession.Wait, throwOnTimeout: false).Success;
        Assert.True(shown);
        app.Screenshot("27-home-dropped");

        // A check on either row is a check on the connection, so both rows follow it.
        bool AllChecked(bool expected) =>
            Music().All(row => row.Patterns.SelectionItem.Pattern.IsSelected.Value == expected);
        app.Find("SelectButton").AsToggleButton().Toggle();
        Assert.False(app.Find("SelectionFavoriteButton").IsEnabled);
        app.Check(Music()[0]);
        Assert.True(Retry.WhileFalse(() => AllChecked(true), AppSession.Wait, throwOnTimeout: false).Success);
        Assert.True(app.Find("SelectionFavoriteButton").IsEnabled);
        app.Screenshot("28-home-selecting");

        app.Check(Music()[1], isChecked: false);
        Assert.True(Retry.WhileFalse(() => AllChecked(false), AppSession.Wait, throwOnTimeout: false).Success);
        Assert.False(app.Find("SelectionFavoriteButton").IsEnabled);

        app.Check(Music()[1]);
        Assert.True(Retry.WhileFalse(() => AllChecked(true), AppSession.Wait, throwOnTimeout: false).Success);
        app.Find("SelectionFavoriteButton").AsButton().Invoke();
        app.FindByName("Favorites", tree);
    }

    private static string PagedStatus(string range) => $@"^{Regex.Escape(range)} of 3,503 rows · [\d,]+ ms$";

    private static string ConnectionId(string folder) => Guids(folder).First();

    // The library writes the connections first, then the groups.
    private static string GroupId(string folder)
    {
        var text = File.ReadAllText(AppSession.LibraryFile(folder));
        var groups = text.IndexOf("\"groups\"", StringComparison.Ordinal);
        return Regex.Match(text[groups..], "[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}").Value;
    }

    private static IEnumerable<string> Guids(string folder) =>
        Regex.Matches(File.ReadAllText(AppSession.LibraryFile(folder)), "[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}")
            .Select(match => match.Value);
}

// The generic credentials the core writes, read and removed the way it writes them.
internal static partial class Credentials
{
    private const int Generic = 1;

    public static bool Exists(string target)
    {
        if (!CredRead(target, Generic, 0, out var credential))
        {
            return false;
        }

        CredFree(credential);
        return true;
    }

    public static void Delete(string target) => CredDelete(target, Generic, 0);

    [LibraryImport("advapi32.dll", EntryPoint = "CredReadW", StringMarshalling = StringMarshalling.Utf16)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static partial bool CredRead(string target, int type, int flags, out IntPtr credential);

    [LibraryImport("advapi32.dll", EntryPoint = "CredDeleteW", StringMarshalling = StringMarshalling.Utf16)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static partial bool CredDelete(string target, int type, int flags);

    [LibraryImport("advapi32.dll")]
    private static partial void CredFree(IntPtr buffer);
}
