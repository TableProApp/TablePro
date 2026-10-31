using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using TablePro.App.Services;

namespace TablePro.App.Views;

/// <summary>
/// The Saved comparisons menu, as the macOS toolbar's Comparisons button: every saved setup to load, saving the one on
/// screen, and deleting one.
/// </summary>
public sealed partial class CompareTabView
{
    private DropDownButton BuildSavedComparisons()
    {
        var menu = new MenuFlyout { Placement = Microsoft.UI.Xaml.Controls.Primitives.FlyoutPlacementMode.BottomEdgeAlignedRight };
        menu.Opening += (_, _) => FillSavedComparisons(menu);
        var button = new DropDownButton
        {
            Content = new StackPanel
            {
                Orientation = Orientation.Horizontal,
                Spacing = 8,
                Children = { new FontIcon { Glyph = "\xE728", FontSize = 14 }, new TextBlock { Text = Strings.Get("Compare/SavedComparisons") } },
            },
            Flyout = menu,
        };
        AutomationProperties.SetName(button, Strings.Get("Compare/SavedComparisons"));
        return button;
    }

    /// <summary>Built each time the menu opens, so a comparison saved from another tab or window is listed.</summary>
    private void FillSavedComparisons(MenuFlyout menu)
    {
        menu.Items.Clear();
        var profiles = ViewModel.SavedProfiles;
        if (profiles.Count == 0)
        {
            menu.Items.Add(new MenuFlyoutItem { Text = Strings.Get("Compare/NothingSaved"), IsEnabled = false });
        }

        foreach (var profile in profiles)
        {
            var item = new MenuFlyoutItem
            {
                Text = profile.Name,
                IsEnabled = !ViewModel.IsRunning,
                Icon = ViewModel.ActiveProfile?.Id == profile.Id ? new FontIcon { Glyph = "\xE73E" } : null,
            };
            ToolTipService.SetToolTip(item, ViewModel.DescribeProfile(profile));
            item.Click += async (_, _) => await ViewModel.LoadProfileAsync(profile);
            menu.Items.Add(item);
        }

        menu.Items.Add(new MenuFlyoutSeparator());
        var save = new MenuFlyoutItem { Text = Strings.Get("Compare/SaveComparison"), Icon = new FontIcon { Glyph = "\xE74E" } };
        save.Click += async (_, _) => await SaveComparisonAsync();
        menu.Items.Add(save);

        if (profiles.Count > 0)
        {
            var delete = new MenuFlyoutSubItem { Text = Strings.Get("Compare/DeleteComparison"), Icon = new FontIcon { Glyph = "\xE74D" } };
            foreach (var profile in profiles)
            {
                var item = new MenuFlyoutItem { Text = profile.Name };
                item.Click += async (_, _) => await ViewModel.DeleteProfileAsync(profile);
                delete.Items.Add(item);
            }

            menu.Items.Add(delete);
        }
    }

    private async Task SaveComparisonAsync()
    {
        var name = await ViewModel.Context.Dialogs.PromptAsync(
            Strings.Get("Compare/SaveComparisonTitle"),
            Strings.Get("Compare/SaveComparisonLabel"),
            ViewModel.ActiveProfile?.Name ?? string.Empty,
            Strings.Get("Common/Save"));
        if (!string.IsNullOrWhiteSpace(name))
        {
            await ViewModel.SaveProfileAsync(name);
        }
    }
}
