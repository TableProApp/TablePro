using FlaUI.Core.AutomationElements;
using FlaUI.Core.Tools;

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

            // A runner cannot install from an App Installer file (ADR 0020), so the check reads the release channel's file.
            var updateCard = app.Find("UpdateCard");
            var checkedLine = Retry.WhileNull(
                () => updateCard.FindAllDescendants().Select(element => AppSession.TextOf(element)).FirstOrDefault(text =>
                    text.StartsWith("Last checked: ", StringComparison.Ordinal)
                    || text.StartsWith("Couldn't check for updates: Response status code", StringComparison.Ordinal)
                    || text.StartsWith("Couldn't check for updates: the update file", StringComparison.Ordinal)),
                AppSession.Wait,
                throwOnTimeout: false).Result;
            Assert.NotNull(checkedLine);
            app.Screenshot("package-settings");

            // The alias starts the console command with the package's identity, so it finds the same LocalState.
            var alias = Path.Combine(
                Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
                "Microsoft",
                "WindowsApps",
                "tablepro.exe");
            var start = new System.Diagnostics.ProcessStartInfo(alias)
            {
                UseShellExecute = false,
                RedirectStandardInput = true,
                RedirectStandardOutput = true,
                RedirectStandardError = true,
            };
            start.ArgumentList.Add("status");
            start.ArgumentList.Add("--format");
            start.ArgumentList.Add("json");
            start.Environment.Remove("TABLEPRO_DATA_DIR");
            var started = System.Diagnostics.Process.Start(start)
                ?? throw new InvalidOperationException("The tablepro alias did not start.");
            started.StandardInput.Close();
            var status = Finish(started);
            Assert.Contains("\"running\":true", status.Out, StringComparison.Ordinal);
            if (!string.IsNullOrEmpty(version))
            {
                Assert.Contains($"\"version\":\"{version}\"", status.Out, StringComparison.Ordinal);
            }

            app.Close();
        }

        // Started with no TABLEPRO_DATA_DIR, the app finds LocalState through its package identity.
        Assert.True(File.Exists(Path.Combine(folder, "session.json")), $"No session.json in {folder}.");
    }
}
