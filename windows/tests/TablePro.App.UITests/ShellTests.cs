using FlaUI.Core.AutomationElements;
using FlaUI.Core.Input;
using FlaUI.Core.Tools;
using FlaUI.Core.WindowsAPI;

namespace TablePro.App.UITests;

// One class, so xunit runs these one at a time: they share the screen, the mouse and the keyboard.
public sealed partial class ShellTests
{
    public static TheoryData<string> Themes => ["Light", "Dark"];

    [Theory]
    [MemberData(nameof(Themes))]
    public void FirstRunShowsGetStartedAndNoRail(string theme)
    {
        using var app = AppSession.Launch(theme);

        foreach (var card in new[] { "NewConnectionCard", "OpenFileCard", "ImportCard", "SampleCard" })
        {
            Assert.True(app.Find(card).IsEnabled, card);
        }

        Assert.True(app.TryFind("ConnectionTree") is null or { IsOffscreen: true });
        Assert.True(app.TryFind("HomeItem") is null or { IsOffscreen: true });
        Assert.True(app.Find("FileMenu").IsEnabled);
        app.Screenshot("01-first-run");
    }

    [Theory]
    [MemberData(nameof(Themes))]
    public void SettingsOpenAsAPageAndApplyAtOnce(string theme)
    {
        using var app = AppSession.Launch(theme);

        app.Find("SettingsButton").AsButton().Invoke();
        app.Find("SettingsPage");
        app.Screenshot("07-settings");
        var reopen = app.Find("ReopenSwitch").AsToggleButton();
        reopen.Toggle();

        var saved = Retry.WhileFalse(
            () => File.ReadAllText(Path.Combine(app.DataFolder, "settings.json")).Contains("\"reopenSession\": false", StringComparison.Ordinal),
            AppSession.Wait,
            throwOnTimeout: false).Success;
        Assert.True(saved);
        app.Find("AboutExpander");
    }

    [Theory]
    [MemberData(nameof(Themes))]
    public void ANewSqliteConnectionConnectsListsTablesAndOpensOne(string theme)
    {
        var folder = AppSession.NewDataFolder(theme);
        var database = AppSession.SampleDatabase(folder);
        using (var app = AppSession.Relaunch(folder, theme))
        {
            app.Click(app.Find("NewConnectionCard"), () => app.HasWindow("New connection"));
            var form = app.WaitForWindow("New connection");
            app.Find("EngineGrid", form);
            app.Screenshot("02-form-engines", form);
            app.Click(app.Find("Engine_sqlite", form), () => app.TryFind("FileBox", form) is not null, form);
            app.Find("FileBox", form).AsTextBox().Text = database;
            app.Find("NameBox", form).AsTextBox().Text = "Chinook copy";
            app.Screenshot("03-form-details", form);
            app.Find("ConnectButton", form).AsButton().Invoke();
            app.WaitForClose("New connection");

            var tree = app.Find("ObjectTree");
            var album = app.FindByName("Album", tree);
            Assert.False(app.Find("Rail_Chinook copy").IsOffscreen);
            app.Screenshot("04-workspace");

            app.Click(album, () => app.TryFind("TableStatus") is not null);
            var status = app.Find("TableStatus");
            var text = AppSession.WaitForText(status, value => value.StartsWith("Rows: 347", StringComparison.Ordinal));
            Assert.StartsWith("Rows: 347", text, StringComparison.Ordinal);
            var grid = app.Find("ResultsGrid");
            Assert.Equal("1", AppSession.Cell(grid, 0, 0));
            app.Screenshot("05-table");

            // The table sorts on the server, and the header reports the order as its ItemStatus.
            var title = () => app.FindByName("Title", grid);
            Assert.Equal(string.Empty, title().Properties.ItemStatus.ValueOrDefault ?? string.Empty);
            title().Patterns.Transform.Pattern.Resize(300, title().BoundingRectangle.Height);
            Assert.Equal(300, AppSession.WaitForWidth(title, 300), 1.0);
            var unsorted = AppSession.Cell(grid, 0, 1);
            app.SortBy(grid, "Title");
            var ascending = app.WaitForCell(grid, 0, 1, value => value.Length > 0 && value != unsorted);
            Assert.True(string.CompareOrdinal(ascending, AppSession.Cell(grid, 1, 1)) <= 0);
            Assert.Equal("Sorted ascending", AppSession.WaitForItemStatus(title, "Sorted ascending"));
            app.SortBy(grid, "Title");
            var descending = app.WaitForCell(grid, 0, 1, value => value.Length > 0 && value != ascending);
            Assert.True(string.CompareOrdinal(descending, AppSession.Cell(grid, 1, 1)) >= 0);
            Assert.Equal("Sorted descending", AppSession.WaitForItemStatus(title, "Sorted descending"));
            Assert.Equal(300, title().BoundingRectangle.Width, 1.0);
            Assert.StartsWith("Rows: 347", app.Find("TableStatus").Name, StringComparison.Ordinal);
            app.Screenshot("05-table-sorted");

            app.Find("Tabs");
            app.Chord(() => app.TryFind("SqlEditor") is not null, VirtualKeyShort.CONTROL, VirtualKeyShort.KEY_T);
            var editor = app.Find("SqlEditor");
            app.TypeInto(editor, "SELECT Name FROM Artist");
            app.Chord(
                () => app.Find("QueryStatus").Properties.Name.ValueOrDefault?.StartsWith("Rows: 275", StringComparison.Ordinal) == true,
                VirtualKeyShort.CONTROL,
                VirtualKeyShort.ENTER);
            var query = AppSession.WaitForText(app.Find("QueryStatus"), value => value.StartsWith("Rows: 275", StringComparison.Ordinal));
            Assert.StartsWith("Rows: 275", query, StringComparison.Ordinal);
            var results = app.Find("ResultsGrid");
            Assert.Equal("AC/DC", AppSession.Cell(results, 0, 0));
            // Sized to the header and the first rows, past the default 140.
            Assert.True(app.FindByName("Name", results).BoundingRectangle.Width > 160);
            app.Screenshot("06-query");

            // A query result sorts by running its statement again, as on macOS.
            app.SortBy(results, "Name");
            var first = app.WaitForCell(results, 0, 0, value => value.Length > 0 && value != "AC/DC");
            Assert.True(string.CompareOrdinal(first, AppSession.Cell(results, 1, 0)) <= 0);
            Assert.StartsWith(
                "Rows: 275",
                AppSession.WaitForText(app.Find("QueryStatus"), value => value.StartsWith("Rows: 275", StringComparison.Ordinal)),
                StringComparison.Ordinal);

            // A script cannot run again for a sort, so the rows it returned are sorted where they are.
            app.TypeInto(editor, "SELECT Name FROM Artist ORDER BY ArtistId; SELECT 1");
            app.Chord(
                () => results.Patterns.Grid.Pattern.GetItem(0, 0)?.Properties.Name.ValueOrDefault == "AC/DC",
                VirtualKeyShort.CONTROL,
                VirtualKeyShort.ENTER);
            app.WaitForCell(results, 0, 0, value => value == "AC/DC");
            app.SortBy(results, "Name");
            var held = AppSession.WaitForText(app.Find("QueryStatus"), value => value.Contains("sorted the rows shown", StringComparison.Ordinal));
            Assert.Equal("Rows: 275 · sorted the rows shown", held);
            var top = app.WaitForCell(results, 0, 0, value => value.Length > 0 && value != "AC/DC");
            Assert.True(string.CompareOrdinal(top, AppSession.Cell(results, 1, 0)) <= 0);
            Assert.Equal("Sorted ascending", AppSession.WaitForItemStatus(() => app.FindByName("Name", results), "Sorted ascending"));
            app.Screenshot("06-query-sorted-held");
            app.Close();
        }

        // The previous session comes back, with the front connection connected.
        using var again = AppSession.Relaunch(folder, theme);
        again.FindByName("Album", again.Find("ObjectTree"));
        again.Find("SqlEditor");
        again.Screenshot("08-restored");
    }

    [Theory]
    [MemberData(nameof(Themes))]
    public void TheSampleDatabaseIsSavedAndListedOnTheConnectionsPage(string theme)
    {
        using var app = AppSession.Launch(theme);

        app.Click(app.Find("SampleCard"), () => app.TryFind("Rail_Chinook (Sample)") is not null);
        app.FindByName("Track", app.Find("ObjectTree"));
        app.Find("HomeItem").AsListBoxItem().Select();
        var tree = app.Find("ConnectionTree");
        app.FindByNamePrefix("Chinook (Sample),", tree);
        app.Screenshot("09-home-library");
    }

    [Theory]
    [MemberData(nameof(Themes))]
    public void AFailedConnectShowsRetryEditAndCopy(string theme)
    {
        using var app = AppSession.Launch(theme);

        app.Click(app.Find("NewConnectionCard"), () => app.HasWindow("New connection"));
        var form = app.WaitForWindow("New connection");
        app.Click(app.Find("Engine_postgres", form), () => app.TryFind("HostBox", form) is not null, form);
        app.Find("HostBox", form).AsTextBox().Text = "127.0.0.1";
        app.Find("PortBox", form).AsTextBox().Text = "1";
        app.Find("UserBox", form).AsTextBox().Text = "nobody";
        app.Find("ConnectButton", form).AsButton().Invoke();
        app.WaitForClose("New connection");

        app.Find("FailureBar");
        Assert.True(app.Find("RetryButton").IsEnabled);
        Assert.True(app.Find("EditConnectionButton").IsEnabled);
        Assert.True(app.Find("CopyDetailsButton").IsEnabled);
        app.Screenshot("10-connect-failed");

        app.Find("EditConnectionButton").AsButton().Invoke();
        var edit = app.WaitForWindow("Edit connection");
        Assert.Equal("127.0.0.1", app.Find("HostBox", edit).AsTextBox().Text);
        app.Find("CancelButton", edit).AsButton().Invoke();
    }

    [Theory]
    [MemberData(nameof(Themes))]
    public void CancellingAConnectTakesItsItemAway(string theme)
    {
        using var app = AppSession.Launch(theme);

        app.Click(app.Find("NewConnectionCard"), () => app.HasWindow("New connection"));
        var form = app.WaitForWindow("New connection");
        app.Click(app.Find("Engine_postgres", form), () => app.TryFind("HostBox", form) is not null, form);
        // A documentation address that drops packets, so the connect waits until cancelled.
        app.Find("HostBox", form).AsTextBox().Text = "192.0.2.1";
        app.Find("NameBox", form).AsTextBox().Text = "Unreachable";
        app.Find("ConnectButton", form).AsButton().Invoke();
        app.WaitForClose("New connection");

        var cancel = app.Find("CancelConnectButton");
        Assert.StartsWith("Connecting to Unreachable", app.Find("ConnectingText").Name, StringComparison.Ordinal);
        app.Screenshot("12-connecting");
        cancel.AsButton().Invoke();

        var gone = Retry.WhileFalse(() => app.TryFind("Rail_Unreachable") is null, AppSession.Wait, throwOnTimeout: false).Success;
        Assert.True(gone);
        app.Find("ConnectionTree");
    }

    [Theory]
    [MemberData(nameof(Themes))]
    public void TheFormMarksAMissingHostAtTheField(string theme)
    {
        using var app = AppSession.Launch(theme);

        app.Click(app.Find("NewConnectionCard"), () => app.HasWindow("New connection"));
        var form = app.WaitForWindow("New connection");
        app.Click(app.Find("Engine_mysql", form), () => app.TryFind("HostBox", form) is not null, form);
        app.Find("HostBox", form).AsTextBox().Text = string.Empty;
        app.Find("TestButton", form).AsButton().Invoke();

        var status = AppSession.WaitForText(app.Find("FormStatus", form), value => value.Length > 0);
        Assert.Equal("Fix the marked fields", status);
        app.Screenshot("11-form-error", form);
    }
}
