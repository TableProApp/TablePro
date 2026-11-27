using FlaUI.Core.AutomationElements;
using FlaUI.Core.Tools;

namespace TablePro.App.UITests;

// No test signs in: each launch starts signed out, as a new machine does, and nothing reaches tablepro.app.
public sealed partial class ShellTests
{
    [Theory]
    [MemberData(nameof(Themes))]
    public void SettingsShowTheAccountSignedOutWithSignIn(string theme)
    {
        using var app = AppSession.Launch(theme);

        app.Find("SettingsButton").AsButton().Invoke();
        app.Find("SettingsPage");
        var button = app.Find("AccountButton");

        Assert.Equal("Sign in...", button.Name);
        Assert.True(app.TryFind("DevicesExpander") is null or { IsOffscreen: true });
        app.Screenshot("60-settings-account");
    }

    [Theory]
    [MemberData(nameof(Themes))]
    public void SettingsListThePlansFeaturesThisAppHasWithTheLicensingLinks(string theme)
    {
        using var app = AppSession.Launch(theme);

        app.Find("SettingsButton").AsButton().Invoke();
        app.Find("SettingsPage");

        // Open from the start, as the plan's features are a section of their own on macOS.
        app.FindByName("Pro options for shared links", app.Find("PlanFeaturesExpander"));
        app.FindByName("Not included", app.Find("PlanFeature_service_sync"));
        app.FindByName("Not included", app.Find("PlanFeature_shared_links"));
        Assert.Equal("Buy a license", app.Find("BuyLicenseLink").Name);
        Assert.Equal("Learn more about licensing", app.Find("LicensingGuideLink").Name);
        app.Screenshot("61-settings-account-features");
    }

    [Theory]
    [MemberData(nameof(Themes))]
    public void SettingsShowSyncOffAndTableProSyncAsksForAPlanWhileSignedOut(string theme)
    {
        using var app = AppSession.Launch(theme);

        app.Find("SettingsButton").AsButton().Invoke();
        app.Find("SettingsPage");
        var provider = app.Find("SyncProviderBox").AsComboBox();
        Assert.Equal("Off", provider.SelectedItem?.Text);
        Assert.True(app.TryFind("SyncCategoriesExpander") is null or { IsOffscreen: true });
        Assert.True(app.TryFind("SyncStatusCard") is null or { IsOffscreen: true });
        provider.Focus();
        app.Screenshot("250-settings-sync");

        provider.Select("TablePro Sync");
        app.FindByName("TablePro Sync needs a paid plan");
        app.Screenshot("251-settings-sync-plan");
        app.CloseDialog();

        var back = Retry.WhileFalse(
            () => app.Find("SyncProviderBox").AsComboBox().SelectedItem?.Text == "Off",
            AppSession.Wait,
            throwOnTimeout: false).Success;
        Assert.True(back);
        Assert.DoesNotContain(
            "\"provider\": \"TableProSync\"",
            File.ReadAllText(Path.Combine(app.DataFolder, "settings.json")),
            StringComparison.Ordinal);
    }
}
