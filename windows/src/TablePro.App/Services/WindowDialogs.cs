using System.Runtime.InteropServices;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;

namespace TablePro.App.Services;

// WinUI opens one ContentDialog per thread, even across windows, and throws on a second, so a second is declined.
internal static class WindowDialogs
{
    private static readonly HashSet<XamlRoot> OpenRoots = [];
    private static TaskCompletionSource? _free;

    public static bool IsOpen(XamlRoot? root) => root is not null && OpenRoots.Contains(root);

    // A dialog nobody asked for just then, as a link from another launch, waits for the window and any open dialog.
    public static async Task<ContentDialogResult> ShowWhenFreeAsync(ContentDialog dialog, FrameworkElement owner)
    {
        ArgumentNullException.ThrowIfNull(dialog);
        ArgumentNullException.ThrowIfNull(owner);
        while (true)
        {
            if (owner.XamlRoot is null || !owner.IsLoaded)
            {
                await LoadedAsync(owner).ConfigureAwait(true);
            }
            else if (OpenRoots.Count > 0)
            {
                await (_free ??= new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously)).Task
                    .ConfigureAwait(true);
            }
            else
            {
                return await ShowAsync(dialog, owner).ConfigureAwait(true);
            }
        }
    }

    private static Task LoadedAsync(FrameworkElement owner)
    {
        var loaded = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        void OnLoaded(object sender, RoutedEventArgs args)
        {
            owner.Loaded -= OnLoaded;
            loaded.TrySetResult();
        }

        owner.Loaded += OnLoaded;
        return loaded.Task;
    }

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
            if (OpenRoots.Count == 0 && _free is { } free)
            {
                _free = null;
                free.TrySetResult();
            }
        }
    }
}
