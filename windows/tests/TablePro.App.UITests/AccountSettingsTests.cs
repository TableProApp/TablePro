using FlaUI.Core.AutomationElements;

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
}
