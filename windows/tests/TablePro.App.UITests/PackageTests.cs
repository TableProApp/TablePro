using FlaUI.Core.AutomationElements;

namespace TablePro.App.UITests;

// The release workflow installs the MSIX and names its family in TABLEPRO_PACKAGE (windows/RELEASING.md).
public sealed partial class ShellTests
{
    private const string NoPackage = "Runs against an installed MSIX, whose family TABLEPRO_PACKAGE names.";

    public static bool PackageInstalled =>
        !string.IsNullOrEmpty(Environment.GetEnvironmentVariable("TABLEPRO_PACKAGE"));

    [Theory(Skip = NoPackage, SkipUnless = nameof(PackageInstalled))]
    [MemberData(nameof(Themes))]
    public void TheInstalledPackageStartsAndKeepsItsFilesInLocalState(string theme)
    {
        var family = Environment.GetEnvironmentVariable("TABLEPRO_PACKAGE")!;
        var version = Environment.GetEnvironmentVariable("TABLEPRO_PACKAGE_VERSION");
        string folder;
        using (var app = AppSession.LaunchPackage(family, theme))
        {
            folder = app.DataFolder;
            foreach (var card in new[] { "NewConnectionCard", "OpenFileCard", "ImportCard", "SampleCard" })
            {
                Assert.True(app.Find(card).IsEnabled, card);
            }

            app.Screenshot("package-first-run");
            app.Find("SettingsButton").AsButton().Invoke();
            app.Find("SettingsPage");
            if (!string.IsNullOrEmpty(version))
            {
                var shown = AppSession.WaitForText(
                    app.Find("VersionText"), text => text.EndsWith(" " + version, StringComparison.Ordinal));
                Assert.EndsWith(" " + version, shown, StringComparison.Ordinal);
            }

            app.Screenshot("package-settings");
            app.Close();
        }

        // Started with no TABLEPRO_DATA_DIR, the app finds LocalState through its package identity.
        Assert.True(File.Exists(Path.Combine(folder, "session.json")), $"No session.json in {folder}.");
    }
}
