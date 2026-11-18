using System.Text.RegularExpressions;
using FlaUI.Core.Tools;

namespace TablePro.App.UITests;

public sealed partial class ShellTests
{
    [Theory]
    [MemberData(nameof(Themes))]
    public void ADatabaseFileAndAScriptOpenFromTheCommandLine(string theme)
    {
        var folder = AppSession.NewDataFolder(theme);
        var database = AppSession.SampleDatabase(folder);
        var script = Path.Combine(folder, "genres.sql");
        File.WriteAllText(script, "SELECT Name FROM Genre ORDER BY Name;");
        using var app = AppSession.LaunchWith(folder, theme, database);

        // The file opens as a connection named after it, which saves nothing to the library.
        app.Find("Rail_" + Path.GetFileName(database));
        app.FindByName("Album", app.Find("ObjectTree"));
        Assert.DoesNotContain(
            Directory.EnumerateFiles(folder, "connections.json", SearchOption.AllDirectories),
            file => File.ReadAllText(file).Contains(Path.GetFileName(database), StringComparison.Ordinal));

        // A second launch from the script's folder hands it over, and it opens in a query tab on the connection.
        app.HandOverFrom(folder, Path.GetFileName(script));
        app.FindByName("genres.sql");
        Assert.True(Retry.WhileFalse(
            () => AppSession.EditorText(app.Find("SqlEditor")).Contains("FROM Genre", StringComparison.Ordinal),
            AppSession.Wait,
            throwOnTimeout: false).Success);
        app.Screenshot("140-file-from-command-line");
    }

    [Theory]
    [MemberData(nameof(Themes))]
    public void AConnectLinkOpensItsTableAndAsksBeforeOpeningItsQuery(string theme)
    {
        const string Sql = "SELECT COUNT(*) FROM Genre;";
        using var app = AppSession.Launch(theme);
        app.Click(app.Find("SampleCard"), () => app.TryFind("Rail_Chinook (Sample)") is not null);
        app.FindByName("Album", app.Find("ObjectTree"));
        var id = SampleConnectionId(app.DataFolder);

        app.HandOver($"tablepro://connect/{id}/table/Genre");
        AppSession.WaitForText(app.Find("TableStatus"), value => value.StartsWith("Rows: 25", StringComparison.Ordinal));

        // A query link shows its SQL first and opens it in a new tab only when asked; nothing runs.
        app.HandOver($"tablepro://connect/{id}/query?sql={Uri.EscapeDataString(Sql)}");
        Assert.Equal(Sql, AppSession.TextOf(app.Find("LinkQueryPreview")));
        app.Screenshot("141-link-query-confirm");
        app.PressDialogButton();
        Assert.True(Retry.WhileFalse(
            () => AppSession.EditorText(app.Find("SqlEditor")).Contains(Sql, StringComparison.Ordinal),
            AppSession.Wait,
            throwOnTimeout: false).Success);
        Assert.False(app.TryFind("QueryStatus") is { } status
            && AppSession.TextOf(status).StartsWith("Rows:", StringComparison.Ordinal));
    }

    [Theory]
    [MemberData(nameof(Themes))]
    public void NotificationsForLongWorkAreSetInSettings(string theme)
    {
        using var app = AppSession.Launch(theme);
        var path = Path.Combine(app.DataFolder, "settings.json");
        app.Find("SettingsButton").AsButton().Invoke();
        app.Find("SettingsPage");

        var after = app.Find("NotifyAfterBox").AsComboBox();
        after.Patterns.ScrollItem.PatternOrDefault?.ScrollIntoView();
        Assert.Equal("20 seconds", after.SelectedItem?.Text);
        after.Select("1 minute");
        Assert.True(Retry.WhileFalse(
            () => File.Exists(path) && File.ReadAllText(path).Contains("\"notifyAfterSeconds\": 60", StringComparison.Ordinal),
            AppSession.Wait,
            throwOnTimeout: false).Success);
        app.Screenshot("142-settings-notifications");

        app.Find("NotifySwitch").AsToggleButton().Toggle();
        Assert.False(app.Find("NotifyAfterBox").IsEnabled);
        Assert.True(Retry.WhileFalse(
            () => File.ReadAllText(path).Contains("\"notifyLongWork\": false", StringComparison.Ordinal),
            AppSession.Wait,
            throwOnTimeout: false).Success);
    }

    private static string SampleConnectionId(string folder)
    {
        var text = File.ReadAllText(AppSession.LibraryFile(folder));
        var connections = text.IndexOf("\"connections\"", StringComparison.Ordinal);
        return Regex.Match(text[connections..], "[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}").Value;
    }
}
