using System.Globalization;
using System.Text.Json;
using FlaUI.Core.AutomationElements;
using FlaUI.Core.Definitions;
using FlaUI.Core.Tools;
using FlaUI.Core.WindowsAPI;
using TablePro.Testing;

namespace TablePro.App.UITests;

// Settings' fonts and history, the production cue, the database switchers, Find and Replace, and .sql files.
public sealed partial class ShellTests
{
    [Theory]
    [MemberData(nameof(Themes))]
    public void SettingsHoldTheFontsTheNullTextAndTheHistoryLimits(string theme)
    {
        using var app = AppSession.Launch(theme);

        app.Find("SettingsButton").AsButton().Invoke();
        app.Find("SettingsPage");
        var nullText = app.Find("NullDisplayBox").AsTextBox();
        nullText.Text = "(null)";
        app.Find("HistoryRetentionBox").AsComboBox().Select("30 days");
        app.Find("GridFontBox").Focus();
        app.Screenshot("90-settings-fonts");
        app.Find("ClearHistorySettingsButton").Focus();
        app.Screenshot("91-settings-history");

        var saved = Retry.WhileFalse(
            () => File.ReadAllText(Path.Combine(app.DataFolder, "settings.json")) is var json
                && json.Contains("\"nullDisplay\": \"(null)\"", StringComparison.Ordinal)
                && json.Contains("\"historyRetentionDays\": 30", StringComparison.Ordinal),
            AppSession.Wait,
            throwOnTimeout: false).Success;
        Assert.True(saved);
    }

    [Theory]
    [MemberData(nameof(Themes))]
    public void AConnectionsColourAndTagsMarkItsWindow(string theme)
    {
        var folder = AppSession.NewDataFolder(theme);
        var database = AppSession.SampleDatabase(folder);
        using var app = AppSession.Relaunch(folder, theme);

        app.Click(app.Find("NewConnectionCard"), () => app.HasWindow("New connection"));
        var form = app.WaitForWindow("New connection");
        app.Click(app.Find("Engine_sqlite", form), () => app.TryFind("FileBox", form) is not null, form);
        app.Find("FileBox", form).AsTextBox().Text = database;
        app.Find("NameBox", form).AsTextBox().Text = "Orders";
        app.Click(app.Find("AppearanceExpander", form), () => app.TryFind("ColorBox", form) is { IsOffscreen: false }, form);
        app.Find("ColorBox", form).AsComboBox().Select("Red");
        app.Find("ConnectButton", form).AsButton().Invoke();
        app.WaitForClose("New connection");
        app.FindByName("Album", app.Find("ObjectTree"));

        app.Find("HomeItem").AsListBoxItem().Select();
        var tree = app.Find("ConnectionTree");
        app.Front();
        app.FindByNamePrefix("Orders,", tree).RightClick();
        app.OpenSubmenu("Tags", "New tag...").Patterns.Invoke.Pattern.Invoke();
        app.Find("NameDialogBox").AsTextBox().Text = "production";
        app.PressDialogButton();
        Retry.WhileFalse(
            () => app.FindByNamePrefix("Orders,", tree).Name.EndsWith("production", StringComparison.Ordinal),
            AppSession.Wait,
            throwOnTimeout: false);

        app.Find("Rail_Orders").AsListBoxItem().Select();
        app.FindByName("Album", app.Find("ObjectTree"));
        var label = Retry.WhileNull(() => app.TryFind("EnvironmentLabel"), AppSession.Wait, throwOnTimeout: false).Result;
        Assert.NotNull(label);
        Assert.Equal("Environment: production", label.Name);
        app.Screenshot("92-production-cue");

        app.Find("HomeItem").AsListBoxItem().Select();
        Assert.True(Retry.WhileFalse(() => app.TryFind("EnvironmentLabel") is null, AppSession.Wait, throwOnTimeout: false).Success);
    }

    [Theory]
    [MemberData(nameof(Themes))]
    public void FindAndReplaceTakeARegularExpressionAndItsGroups(string theme)
    {
        using var app = AppSession.Launch(theme);
        app.Click(app.Find("SampleCard"), () => app.TryFind("Rail_Chinook (Sample)") is not null);
        app.FindByName("Track", app.Find("ObjectTree"));
        app.TypeInto("Query 1", "select 1 as one, 2 as two");

        app.FindEditor("Query 1").Focus();
        app.Chord(() => app.TryFind("ReplaceBox") is { IsOffscreen: false }, VirtualKeyShort.CONTROL, VirtualKeyShort.KEY_H);
        app.Find("FindRegexToggle").AsToggleButton().Toggle();
        app.Find("FindBox").AsTextBox().Text = @"(\d) as";
        app.Find("ReplaceBox").AsTextBox().Text = "$1 AS";
        app.Screenshot("95-find-replace");
        app.Find("ReplaceAllButton").AsButton().Invoke();

        var replaced = Retry.WhileFalse(
            () => AppSession.EditorText(app.FindEditor("Query 1")).TrimEnd('\r', '\n') == "select 1 AS one, 2 AS two",
            AppSession.Wait,
            throwOnTimeout: false).Success;
        Assert.True(replaced, AppSession.EditorText(app.FindEditor("Query 1")));
    }

    [Theory]
    [MemberData(nameof(Themes))]
    public void ASqlFileTabSavesBackToItsFileAndIsListedUnderOpenRecent(string theme)
    {
        var folder = AppSession.NewDataFolder(theme);
        var database = AppSession.SampleDatabase(folder);
        var file = Path.Combine(folder, "report.sql");
        File.WriteAllText(file, "SELECT 1");
        var state = new
        {
            connections = new[]
            {
                new
                {
                    filePath = database,
                    name = "Reports",
                    engineId = "sqlite",
                    tabs = new[] { new { kind = "Query", title = "report.sql", sql = "SELECT 1", filePath = file } },
                },
            },
            front = 0,
            recentFiles = new[] { file },
        };
        File.WriteAllText(Path.Combine(folder, "session.json"), JsonSerializer.Serialize(state));
        using var app = AppSession.Relaunch(folder, theme);

        app.TypeInto("report.sql", "SELECT 2 AS saved");
        var tabs = app.Find("Tabs");
        bool Dirty() => tabs.FindFirstDescendant(condition =>
            condition.ByControlType(ControlType.TabItem).And(condition.ByName("report.sql"))) is { } tab
            && tab.Properties.ItemStatus.ValueOrDefault == "Unsaved changes";
        Assert.True(Retry.WhileFalse(Dirty, AppSession.Wait, throwOnTimeout: false).Success);
        app.Screenshot("96-sql-file-unsaved");

        app.Chord(() => File.ReadAllText(file) == "SELECT 2 AS saved", VirtualKeyShort.CONTROL, VirtualKeyShort.KEY_S);
        Assert.True(Retry.WhileFalse(() => !Dirty(), AppSession.Wait, throwOnTimeout: false).Success);

        app.Click(app.Find("FileMenu"), () => app.TryFindMenuItem("Open recent") is not null);
        app.OpenSubmenu("Open recent", file);
        app.Screenshot("97-open-recent");
    }

    [Theory]
    [MemberData(nameof(Themes))]
    public void APostgresTabRunsInAnotherDatabaseAndTheConnectionOpensOneBesideIt(string theme)
    {
        Assert.SkipUnless(SshTestEnvironment.Available, "Requires the Windows PostgreSQL fixture.");
        using var app = AppSession.Launch(theme);
        app.Click(app.Find("NewConnectionCard"), () => app.HasWindow("New connection"));
        var form = app.WaitForWindow("New connection");
        app.Click(app.Find("Engine_postgres", form), () => app.TryFind("HostBox", form) is not null, form);
        app.Find("NameBox", form).AsTextBox().Text = "Server";
        app.Find("HostBox", form).AsTextBox().Text = "127.0.0.1";
        app.Find("PortBox", form).AsTextBox().Text = SshTestEnvironment.DatabasePort.ToString(CultureInfo.InvariantCulture);
        app.Find("UserBox", form).AsTextBox().Text = "tablepro_ssh";
        app.Find("DatabaseBox", form).AsTextBox().Text = "tablepro_ssh";
        app.Find("PasswordInput", form).Patterns.Value.Pattern.SetValue(SshTestEnvironment.DatabasePassword);
        app.Find("ConnectButton", form).AsButton().Invoke();
        app.WaitForClose("New connection");
        app.FindByName("ssh_proof", app.Find("ObjectTree"));
        Assert.Equal("Database: tablepro_ssh", app.Find("DatabaseButton").Name);

        app.Click(app.Find("QueryDatabaseButton"), () => app.TryFindMenuItem("postgres") is not null);
        app.FindMenuItem("postgres").Patterns.Invoke.Pattern.Invoke();
        app.TypeInto("Query 1", "SELECT current_database()");
        app.Chord(
            () => app.Find("QueryStatus").Properties.Name.ValueOrDefault?.StartsWith("Rows: 1", StringComparison.Ordinal) == true,
            VirtualKeyShort.CONTROL,
            VirtualKeyShort.ENTER);
        Assert.Equal("postgres", app.WaitForCell(app.Find("ResultsGrid"), 0, 0, value => value == "postgres"));
        app.Screenshot("93-query-tab-database");

        app.Click(app.Find("DatabaseButton"), () => app.TryFindMenuItem("postgres") is not null);
        app.FindMenuItem("postgres").Patterns.Invoke.Pattern.Invoke();
        var beside = Retry.WhileNull(() => app.TryFind("Rail_Server · postgres"), AppSession.Wait, throwOnTimeout: false).Result;
        Assert.NotNull(beside);
        Assert.True(Retry.WhileFalse(
            () => app.TryFind("DatabaseButton") is { Name: "Database: postgres" },
            AppSession.Wait,
            throwOnTimeout: false).Success);
        app.Screenshot("94-database-beside");
    }
}
