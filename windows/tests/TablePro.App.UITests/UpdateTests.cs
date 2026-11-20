using FlaUI.Core.AutomationElements;
using FlaUI.Core.Tools;

namespace TablePro.App.UITests;

public sealed partial class ShellTests
{
    [Theory]
    [MemberData(nameof(Themes))]
    public void CheckForUpdatesOpensSettingsWhereTheChannelIsKept(string theme)
    {
        using var app = AppSession.Launch(theme);
        var path = Path.Combine(app.DataFolder, "settings.json");

        app.Click(app.Find("HelpMenu"), () => app.TryFindMenuItem("Check for updates...") is { IsEnabled: true });
        app.Click(app.FindMenuItem("Check for updates..."), () => app.TryFind("UpdateCard") is not null);
        var card = app.Find("UpdateCard");
        // A build that is not installed from its package has no package version and no App Installer file.
        app.FindByName("Only TablePro installed from its package checks for updates.", card);
        Assert.True(app.TryFind("UpdateButton") is null or { IsOffscreen: true });

        var channel = app.Find("UpdateChannelBox").AsComboBox();
        channel.Patterns.ScrollItem.PatternOrDefault?.ScrollIntoView();
        Assert.Equal("Stable", channel.SelectedItem?.Text);
        channel.Select("Beta");
        channel.Collapse();
        Assert.True(Retry.WhileFalse(
            () => File.Exists(path) && File.ReadAllText(path).Contains("\"updateChannel\": \"Beta\"", StringComparison.Ordinal),
            AppSession.Wait,
            throwOnTimeout: false).Success);
        app.Find("WhatsNewLink");
        app.Screenshot("184-settings-updates");
    }
}
