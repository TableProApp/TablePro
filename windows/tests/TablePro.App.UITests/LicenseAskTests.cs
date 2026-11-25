using System.Text.Json;
using FlaUI.Core.AutomationElements;
using FlaUI.Core.Tools;

namespace TablePro.App.UITests;

public sealed partial class ShellTests
{
    // The 30th day of use: the seeded 29 and this launch, with the five quiet minutes cut to none.
    [Theory]
    [MemberData(nameof(Themes))]
    public void TheLicenseAskComesOnTheThirtiethDayOfUseAndNotNowKeepsItAway(string theme)
    {
        var folder = AppSession.NewDataFolder(theme);
        var settings = Path.Combine(folder, "settings.json");
        File.WriteAllText(
            settings,
            JsonSerializer.Serialize(new Dictionary<string, object>
            {
                ["theme"] = theme,
                ["setupGuideSeen"] = true,
                ["usageDays"] = 29,
                ["lastUsageDay"] = "2000-01-01",
            }));
        var environment = new Dictionary<string, string> { ["TABLEPRO_LICENSE_ASK_QUIET_SECONDS"] = "0" };

        using (var app = AppSession.LaunchWithEnvironment(folder, theme, environment))
        {
            app.Front();
            // A closed InfoBar stays in the tree with its content folded away, so its buttons say whether it shows.
            Assert.True(Retry.WhileFalse(
                () => app.TryFind("LicenseAskBuy") is { IsOffscreen: false },
                AppSession.Wait,
                throwOnTimeout: false).Success);
            var bar = app.Find("LicenseAskBar");
            app.FindByName("You've used TablePro on 30 days", bar);
            Assert.Equal("Buy a license", app.Find("LicenseAskBuy").Name);
            Assert.Equal("I use it personally", app.Find("LicenseAskPersonal").Name);
            app.Screenshot("62-license-ask");

            var close = bar.FindFirstDescendant(condition => condition.ByAutomationId("CloseButton"));
            Assert.NotNull(close);
            close.AsButton().Invoke();
            Assert.True(
                Retry.WhileFalse(
                    () => File.ReadAllText(settings).Contains("\"licenseAskAnswer\": \"NotNow\"", StringComparison.Ordinal),
                    AppSession.Wait,
                    throwOnTimeout: false).Success,
                File.ReadAllText(settings));
        }

        using var again = AppSession.LaunchWithEnvironment(folder, theme, environment);
        again.Front();
        again.Find("SettingsButton");
        // Asked today, so the next ask is 90 days away; give the account time to open before looking.
        Assert.False(Retry.WhileFalse(
            () => again.TryFind("LicenseAskBuy") is { IsOffscreen: false },
            TimeSpan.FromSeconds(5),
            throwOnTimeout: false).Success);
    }
}
