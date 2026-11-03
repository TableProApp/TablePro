using System.Security.Cryptography;
using FlaUI.Core.AutomationElements;
using FlaUI.Core.Tools;

namespace TablePro.App.UITests;

// Settings > Drivers, with a catalog in the data folder that lists the SQLite driver windows.yml built and signed
// with a test certificate; the Debug app trusts that certificate through TABLEPRO_DRIVER_SIGNER.
public sealed partial class ShellTests
{
    [Theory]
    [MemberData(nameof(Themes))]
    public void ADriverFromTheCatalogInstallsIsListedAndRemoved(string theme)
    {
        var driver = Environment.GetEnvironmentVariable("TABLEPRO_TEST_DRIVER");
        var signer = Environment.GetEnvironmentVariable("TABLEPRO_TEST_DRIVER_SIGNER");
        var issuer = Environment.GetEnvironmentVariable("TABLEPRO_TEST_DRIVER_SIGNER_ISSUER");
        var version = Environment.GetEnvironmentVariable("TABLEPRO_TEST_DRIVER_VERSION");
        Assert.SkipWhen(
            driver is null || signer is null || issuer is null || version is null,
            "windows.yml signs the test driver");
        var folder = AppSession.NewDataFolder(theme);
        var catalog = Path.Combine(folder, "catalog.json");
        var arch = System.Runtime.InteropServices.RuntimeInformation.ProcessArchitecture
            == System.Runtime.InteropServices.Architecture.Arm64 ? "aarch64" : "x86_64";
        var sha256 = Convert.ToHexStringLower(SHA256.HashData(File.ReadAllBytes(driver!)));
        File.WriteAllText(catalog, $$"""
            {"schemaVersion": 1, "plugins": [{"id": "sqlite", "name": "SQLite", "databaseTypeIds": ["sqlite"],
              "releases": [{"version": "{{version}}", "build": 1, "channel": "stable", "abi": 1, "os": "windows",
                "arch": "{{arch}}", "url": "{{new Uri(driver!).AbsoluteUri}}", "sha256": "{{sha256}}"}]}]}
            """);
        var environment = new Dictionary<string, string>
        {
            ["TABLEPRO_DRIVER_REGISTRY"] = catalog,
            ["TABLEPRO_DRIVER_SIGNER"] = signer!,
            ["TABLEPRO_DRIVER_SIGNER_ISSUER"] = issuer!,
        };
        using var app = AppSession.Relaunch(folder, theme, environment: environment);

        app.Find("SettingsButton").AsButton().Invoke();
        app.Find("SettingsPage");
        app.Find("NoDrivers");
        WaitUntilEnabled(app, "InstallDriver_sqlite");
        // Focus brings the section into view, as tabbing to it would.
        app.Find("InstallDriver_sqlite").Focus();
        app.Screenshot("08-drivers-available");
        app.Find("InstallDriver_sqlite").AsButton().Invoke();

        var installed = app.Find("InstalledDriver_sqlite");
        app.FindByName($"Version {version}", installed);
        app.FindByName($"SQLite {version} is installed.");
        Assert.NotEmpty(Directory.EnumerateFiles(Path.Combine(folder, "drivers"), "*.dll", SearchOption.AllDirectories));
        WaitUntilEnabled(app, "RemoveDriver_sqlite");
        app.Find("RemoveDriver_sqlite").Focus();
        app.Screenshot("09-drivers-installed");

        app.Find("RemoveDriver_sqlite").AsButton().Invoke();

        app.Find("NoDrivers");
        WaitUntilEnabled(app, "InstallDriver_sqlite");
    }

    // The cards are rebuilt as the lists change, so each look finds the button again.
    private static void WaitUntilEnabled(AppSession app, string automationId) =>
        Assert.True(
            Retry.WhileFalse(() => app.TryFind(automationId) is { IsEnabled: true }, AppSession.Wait, throwOnTimeout: false).Success,
            $"{automationId} never became enabled.");
}
