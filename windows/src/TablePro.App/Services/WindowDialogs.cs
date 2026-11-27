using System.Runtime.InteropServices;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;

namespace TablePro.App.Services;

// WinUI opens one ContentDialog per thread, even across windows, and throws on a second, so a second is declined.
internal static class WindowDialogs
{
    private static readonly HashSet<XamlRoot> OpenRoots = [];
    // Answered dialogs still playing their closing transition, and questions asked during one.
    private static int _closing;
    private static int _waiting;
    private static TaskCompletionSource? _changed;

    // An answered dialog no longer counts as open, though it still plays its closing transition.
    public static bool IsOpen(XamlRoot? root) => root is not null && OpenRoots.Contains(root);

    // A dialog nobody asked for just then waits for the window and any open dialog; a cancel while it waits gives None.
    public static async Task<ContentDialogResult> ShowWhenFreeAsync(
        ContentDialog dialog, FrameworkElement owner, CancellationToken cancellationToken = default)
    {
        ArgumentNullException.ThrowIfNull(dialog);
        ArgumentNullException.ThrowIfNull(owner);
        try
        {
            while (true)
            {
                cancellationToken.ThrowIfCancellationRequested();
                if (owner.XamlRoot is null || !owner.IsLoaded)
                {
                    await LoadedAsync(owner).WaitAsync(cancellationToken).ConfigureAwait(true);
                }
                else if (OpenRoots.Count > 0 || _closing > 0 || _waiting > 0)
                {
                    await ChangedAsync().WaitAsync(cancellationToken).ConfigureAwait(true);
                }
                else
                {
                    return await ShowNowAsync(dialog, owner).ConfigureAwait(true);
                }
            }
        }
        catch (OperationCanceledException)
        {
            return ContentDialogResult.None;
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

    // A question asked during the last answer's closing transition, as a click right after Cancel, waits its turn.
    public static async Task<ContentDialogResult> ShowAsync(
        ContentDialog dialog, FrameworkElement owner, CancellationToken cancellationToken = default)
    {
        if (OpenRoots.Count == 0 && _closing > 0)
        {
            _waiting++;
            try
            {
                while (OpenRoots.Count > 0 || _closing > 0)
                {
                    await ChangedAsync().WaitAsync(cancellationToken).ConfigureAwait(true);
                }
            }
            catch (OperationCanceledException)
            {
                return ContentDialogResult.None;
            }
            finally
            {
                _waiting--;
                Changed();
            }
        }

        return cancellationToken.IsCancellationRequested
            ? ContentDialogResult.None
            : await ShowNowAsync(dialog, owner).ConfigureAwait(true);
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
                OpenRoots.Remove(root);
                Changed();
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
            if (answered)
            {
                _closing--;
            }
            else
            {
                OpenRoots.Remove(root);
            }

            Changed();
        }
    }

    private static Task ChangedAsync() =>
        (_changed ??= new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously)).Task;

    private static void Changed()
    {
        if (_changed is { } changed)
        {
            _changed = null;
            changed.TrySetResult();
        }
    }
}
