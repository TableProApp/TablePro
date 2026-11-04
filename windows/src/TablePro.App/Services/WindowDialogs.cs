using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;

namespace TablePro.App.Services;

internal static class WindowDialogs
{
    private static readonly HashSet<XamlRoot> OpenRoots = [];

    public static bool IsOpen(XamlRoot? root) => root is not null && OpenRoots.Contains(root);

    public static async Task<ContentDialogResult> ShowAsync(ContentDialog dialog, FrameworkElement owner)
    {
        if (owner.XamlRoot is not { } root || !OpenRoots.Add(root))
        {
            return ContentDialogResult.None;
        }

        // Closing or moving the owner must dismiss its prompt before that root is gone.
        void OnUnloaded(object sender, RoutedEventArgs args) => dialog.Hide();
        owner.Unloaded += OnUnloaded;
        try
        {
            dialog.XamlRoot = root;
            return await dialog.ShowAsync();
        }
        finally
        {
            owner.Unloaded -= OnUnloaded;
            OpenRoots.Remove(root);
        }
    }
}
