using System.Runtime.InteropServices;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;

namespace TablePro.App.Services;

// WinUI opens one ContentDialog per thread, even across windows, and throws on a second, so a second is declined.
internal static class WindowDialogs
{
    private static readonly HashSet<XamlRoot> OpenRoots = [];
    private static int _closing;
    private static TaskCompletionSource? _free;
    private static TaskCompletionSource? _closed;

    // An answered dialog still plays its closing transition, but no longer counts as open.
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
            else if (_closing > 0)
            {
                await ClosedAsync().ConfigureAwait(true);
            }
            else
            {
                return await ShowNowAsync(dialog, owner).ConfigureAwait(true);
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

    private static Task ClosedAsync() =>
        (_closed ??= new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously)).Task;

    // A question asked during the last answer's closing transition, as a click right after Cancel, waits for it.
    public static async Task<ContentDialogResult> ShowAsync(
        ContentDialog dialog, FrameworkElement owner, CancellationToken cancellationToken = default)
    {
        while (OpenRoots.Count == 0 && _closing > 0)
        {
            try
            {
                await ClosedAsync().WaitAsync(cancellationToken).ConfigureAwait(true);
            }
            catch (OperationCanceledException)
            {
                return ContentDialogResult.None;
            }
        }

        return await ShowNowAsync(dialog, owner).ConfigureAwait(true);
    }

    private static async Task<ContentDialogResult> ShowNowAsync(ContentDialog dialog, FrameworkElement owner)
    {
        if (owner.XamlRoot is not { } root || OpenRoots.Count > 0)
        {
            return ContentDialogResult.None;
        }

        OpenRoots.Add(root);
        var answered = false;
        void OnClosing(ContentDialog sender, ContentDialogClosingEventArgs args)
        {
            if (!args.Cancel && !answered)
            {
                answered = true;
                _closing++;
                Release(root);
            }
        }

        // Closing or moving the owner must dismiss its prompt before that root is gone.
        void OnUnloaded(object sender, RoutedEventArgs args) => dialog.Hide();
        dialog.Closing += OnClosing;
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
            dialog.Closing -= OnClosing;
            owner.Unloaded -= OnUnloaded;
            if (!answered)
            {
                Release(root);
            }
            else if (--_closing == 0 && _closed is { } closed)
            {
                _closed = null;
                closed.TrySetResult();
            }
        }
    }

    private static void Release(XamlRoot root)
    {
        OpenRoots.Remove(root);
        if (OpenRoots.Count == 0 && _free is { } free)
        {
            _free = null;
            free.TrySetResult();
        }
    }
}
