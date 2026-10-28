using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using TablePro.App.Services;
using TablePro.Core.Updates;

namespace TablePro.App.Views;

/// <summary>The Check for Updates flow shared by the menu, Settings and a critical update found in the background.</summary>
internal static class UpdateDialogs
{
    public static async Task CheckAsync(UpdateService updates, DialogService dialogs)
    {
        var offer = await updates.CheckAsync(userInitiated: true);
        if (offer is null)
        {
            await dialogs.ShowErrorAsync("Check for Updates", updates.LastError ?? updates.StatusText);
            return;
        }

        await OfferAsync(updates, dialogs, offer);
    }

    public static async Task OfferAsync(UpdateService updates, DialogService dialogs, UpdateOffer offer)
    {
        var body = new StackPanel { Spacing = 12, MaxWidth = 520 };
        body.Children.Add(new TextBlock
        {
            Text = $"TablePro {offer.Version} is available. You have {updates.CurrentVersion}.",
            TextWrapping = TextWrapping.Wrap,
        });
        if (!string.IsNullOrWhiteSpace(offer.Item.Notes))
        {
            body.Children.Add(new ScrollViewer
            {
                MaxHeight = 260,
                Content = new TextBlock { Text = offer.Item.Notes, TextWrapping = TextWrapping.Wrap, IsTextSelectionEnabled = true },
            });
        }

        var primary = updates.Mode == UpdateInstallMode.AppInstaller ? "Restart to Update" : "Install and Restart";

        // A critical release cannot be skipped, as on macOS: it fixes something the installed build gets wrong.
        var dialog = dialogs.Create(offer.IsCritical ? "Important Update" : "Update Available", body, primary, "Later", offer.IsCritical ? null : "Skip This Version");
        switch (await dialogs.ShowAsync(dialog))
        {
            case ContentDialogResult.Primary:
                try
                {
                    await updates.InstallAsync(offer);
                }
                catch (Exception ex) when (ex is HttpRequestException or IOException or InvalidOperationException or InvalidDataException)
                {
                    await dialogs.ShowErrorAsync("Could not install the update", ex.Message);
                }

                break;
            case ContentDialogResult.Secondary:
                await updates.SkipAsync(offer);
                break;
        }
    }
}
