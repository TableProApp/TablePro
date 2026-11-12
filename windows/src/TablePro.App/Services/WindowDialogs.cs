using System.Runtime.InteropServices;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;

namespace TablePro.App.Services;

// WinUI opens one ContentDialog per thread, even across windows, and throws on a second, so a second is declined.
internal static class WindowDialogs
{
    private static readonly HashSet<XamlRoot> OpenRoots = [];

    public static bool IsOpen(XamlRoot? root) => root is not null && OpenRoots.Contains(root);

    public static async Task<ContentDialogResult> ShowAsync(ContentDialog dialog, FrameworkElement owner)
    {
        if (owner.XamlRoot is not { } root || OpenRoots.Count > 0)
        {
            return ContentDialogResult.None;
        }

        OpenRoots.Add(root);
        // Closing or moving the owner must dismiss its prompt before that root is gone.
        void OnUnloaded(object sender, RoutedEventArgs args) => dialog.Hide();
        owner.Unloaded += OnUnloaded;
        try
        {
            dialog.XamlRoot = root;
            return await dialog.ShowAsync();
        }
        catch (COMException)
        {
            // A dialog this class did not open holds the thread.
            return ContentDialogResult.None;
        }
        finally
        {
            owner.Unloaded -= OnUnloaded;
            OpenRoots.Remove(root);
        }
    }
}
