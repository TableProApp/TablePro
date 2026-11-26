using FlaUI.Core.AutomationElements;
using FlaUI.Core.Tools;

namespace TablePro.App.UITests;

// The setup guide of core 0057 on Windows: shown on an empty library the user has not seen it on, one screenshot a step.
public sealed partial class ShellTests
{
    [Theory]
    [MemberData(nameof(Themes))]
    public void TheSetupGuideWalksEachStepAndOpensTheSampleItRecorded(string theme)
    {
        using var app = AppSession.Launch(theme, setupGuideSeen: false);

        app.Find("SetupTitle");
        app.Find("SetupOtherAppCard");
        Assert.True(app.TryFind("HomeItem") is null or { IsOffscreen: true });
        app.Screenshot("192-setup-origin");

        // Changed on purpose: a card is selected, and Continue goes on (windows/docs/decisions/0026).
        app.Click(app.Find("SetupOtherAppCard"), () => IsCardSelected(app, "SetupOtherAppCard"));
        app.Click(app.Find("SetupPrimary"), () => app.TryFind("SetupSources") is { IsOffscreen: false }
            || app.TryFind("SetupNotFound") is { IsOffscreen: false });
        Assert.True(Retry.WhileFalse(
            () => app.TryFind("SetupPrimary") is { IsEnabled: true },
            AppSession.Wait,
            throwOnTimeout: false).Success);
        app.Screenshot("193-setup-import");

        // The runner has no other database app, so nothing is ticked and the step moves on.
        app.Click(app.Find("SetupPrimary"), () => app.TryFind("SetupSampleCard") is { IsOffscreen: false });
        app.Screenshot("194-setup-first-connection");

        app.Click(app.Find("SetupSampleCard"), () => IsCardSelected(app, "SetupSampleCard"));
        app.Click(app.Find("SetupPrimary"), () => app.TryFind("SetupShortcutsBox") is { IsOffscreen: false });
        Assert.Equal("TablePro", app.Find("SetupShortcutsBox").AsComboBox().SelectedItem?.Text);
        app.Screenshot("195-setup-options");

        app.Click(app.Find("SetupPrimary"), () => app.TryFind("Rail_Chinook (Sample)") is not null);
        app.FindByName("Track", app.Find("ObjectTree"));
        Assert.True(Retry.WhileFalse(
            () => File.ReadAllText(Path.Combine(app.DataFolder, "settings.json"))
                .Contains("\"setupGuideSeen\": true", StringComparison.Ordinal),
            AppSession.Wait,
            throwOnTimeout: false).Success);
    }

    [Theory]
    [MemberData(nameof(Themes))]
    public void SkipLeavesTheSmallerEmptyPageForGoodAndHelpOpensTheGuideAgain(string theme)
    {
        var folder = AppSession.NewDataFolder(theme, setupGuideSeen: false);
        using (var app = AppSession.Relaunch(folder, theme))
        {
            app.Click(app.Find("SetupSkip"), () => app.TryFind("SetupGuideCard") is { IsOffscreen: false });
            app.Find("NewConnectionCard");
            Assert.True(app.TryFind("SetupTitle") is null or { IsOffscreen: true });
            app.Screenshot("196-setup-skipped");

            app.Click(app.Find("HelpMenu"), () => app.TryFind("MenuSetupGuide") is { IsEnabled: true });
            app.Click(app.Find("MenuSetupGuide"), () => app.TryFind("SetupTitle") is { IsOffscreen: false });
            app.Click(app.Find("SetupNewCard"), () => IsCardSelected(app, "SetupNewCard"));
            app.Click(app.Find("SetupPrimary"), () => app.TryFind("SetupSampleCard") is { IsOffscreen: false });
            app.Close();
        }

        // Seen once, the guide stays away while the library is still empty.
        using var again = AppSession.Relaunch(folder, theme);
        again.Find("SetupGuideCard");
        Assert.True(again.TryFind("SetupTitle") is null or { IsOffscreen: true });
    }

    private static bool IsCardSelected(AppSession app, string card) => AppSession.Holds(() =>
        app.TryFind(card)?.Patterns.SelectionItem.PatternOrDefault?.IsSelected.ValueOrDefault == true);
}
