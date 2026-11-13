using System.Runtime.InteropServices;
using Microsoft.UI;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Windows.Security.Credentials.UI;

namespace TablePro.App.Services;

// Reveal masked values asks the device's owner first: Windows Hello where it is set up, else a confirmation.
internal static class MaskReveal
{
    public static async Task<bool> ConfirmAsync(FrameworkElement owner)
    {
        ArgumentNullException.ThrowIfNull(owner);
        if (owner.XamlRoot is not { } root)
        {
            return false;
        }

        if (await HelloAvailableAsync().ConfigureAwait(true))
        {
            // A desktop app names the window Hello's prompt belongs to, through the interop the docs give for it.
            var window = Win32Interop.GetWindowFromWindowId(root.ContentIslandEnvironment.AppWindowId);
            try
            {
                var result = await UserConsentVerifierInterop.RequestVerificationForWindowAsync(
                    window, Strings.Get("RevealMaskedHelloMessage"));
                return result == UserConsentVerificationResult.Verified;
            }
            catch (COMException)
            {
                // The prompt could not open, as on a session without a console; the confirmation stands in.
            }
        }

        var dialog = new ContentDialog
        {
            RequestedTheme = owner.ActualTheme,
            Title = Strings.Get("RevealMaskedTitle"),
            Content = new TextBlock { Text = Strings.Get("RevealMaskedMessage"), TextWrapping = TextWrapping.Wrap },
            PrimaryButtonText = Strings.Get("RevealMaskedButton"),
            CloseButtonText = Strings.Get("Cancel"),
            DefaultButton = ContentDialogButton.Close,
        };
        return await WindowDialogs.ShowAsync(dialog, owner).ConfigureAwait(true) == ContentDialogResult.Primary;
    }

    private static async Task<bool> HelloAvailableAsync()
    {
        try
        {
            return await UserConsentVerifier.CheckAvailabilityAsync() == UserConsentVerifierAvailability.Available;
        }
        catch (COMException)
        {
            return false;
        }
    }
}
