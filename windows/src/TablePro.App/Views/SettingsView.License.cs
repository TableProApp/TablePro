using CommunityToolkit.WinUI.Controls;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using TablePro.App.Model;
using TablePro.App.Services;

namespace TablePro.App.Views;

// The plan's features in the Account section, and the license notices' way into it (docs/decisions/0023).
public sealed partial class SettingsView
{
    private const double FeatureIconSize = 16;

    private void ShowLicenseLinks()
    {
        BuyLicenseLink.NavigateUri = AccountSetup.Pricing("app-settings");
        LicensingGuideLink.NavigateUri = AccountSetup.LicensingGuide;
    }

    // Each row asks the gate, so Included means what a gated feature would find: a lapsed plan is not included.
    private void ShowPlanFeatures(AccountPanel panel)
    {
        PlanFeaturesExpander.Items.Clear();
        foreach (var feature in PlanFeatures.OnWindows)
        {
            PlanFeaturesExpander.Items.Add(FeatureCard(feature.Code, _workbench.Gate(feature.Code) is null));
        }

        PlanFeaturesExpander.Visibility = PlanFeatures.OnWindows.Count > 0 ? Visibility.Visible : Visibility.Collapsed;
        BuyLicenseLink.Visibility = panel.Stage == AccountStage.SignedOut ? Visibility.Visible : Visibility.Collapsed;
    }

    private static SettingsCard FeatureCard(string code, bool included)
    {
        var state = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8 };
        state.Children.Add(new FontIcon { Glyph = included ? "" : "", FontSize = FeatureIconSize });
        state.Children.Add(new TextBlock
        {
            Text = included ? Strings.Get("PlanFeatureIncluded") : Strings.Get("PlanFeatureNotIncluded"),
            VerticalAlignment = VerticalAlignment.Center,
        });
        var card = new SettingsCard
        {
            Header = LicenseText.FeatureName(code),
            Description = LicenseText.FeatureDescription(code),
            Content = state,
        };
        AutomationProperties.SetAutomationId(card, "PlanFeature_" + code);
        return card;
    }

    // From a license notice elsewhere in the app: this section is where the account is signed in to and checked.
    public async Task SignInAsync()
    {
        AccountCard.StartBringIntoView();
        if (_workbench.AccountPanel.Stage is AccountStage.SignedOut)
        {
            await StartSignInAsync();
        }
    }

    public async Task RefreshAccountAsync()
    {
        AccountCard.StartBringIntoView();
        await RunAccountAsync(account => account.RefreshAsync());
    }

    public void ShowAccountSection() => AccountCard.StartBringIntoView();
}
