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

    internal static void Probe(string line)
    {
        try
        {
            File.AppendAllText(Path.Combine(Path.GetTempPath(), "tablepro-probe-app.log"),
                DateTime.Now.ToString("HH:mm:ss.ffffff", System.Globalization.CultureInfo.InvariantCulture) + " APP " + line + "\n");
        }
        catch (IOException)
        {
        }
    }

    internal static string Describe(FrameworkElement element) =>
        $"{element.GetType().Name}#{System.Runtime.CompilerServices.RuntimeHelpers.GetHashCode(element)} root={element.XamlRoot is not null} loaded={element.IsLoaded} parent={element.Parent is not null} vparent={Microsoft.UI.Xaml.Media.VisualTreeHelper.GetParent(element) is not null}";

    public static async Task<ContentDialogResult> ShowAsync(ContentDialog dialog, FrameworkElement owner)
    {
        Probe($"show '{dialog.Title}' owner={Describe(owner)} open={OpenRoots.Count}");
        if (owner.XamlRoot is not { } root || OpenRoots.Count > 0)
        {
            Probe("  declined");
            return ContentDialogResult.None;
        }

        OpenRoots.Add(root);
        // Closing or moving the owner must dismiss its prompt before that root is gone.
        void OnUnloaded(object sender, RoutedEventArgs args)
        {
            Probe($"  owner unloaded: {Describe(owner)} sameRoot={ReferenceEquals(owner.XamlRoot, root)}");
            dialog.Hide();
        }
        dialog.Opened += (_, _) => Probe("  opened");
        dialog.Closing += (_, e) => Probe($"  closing {e.Result}");
        dialog.Closed += (_, e) => Probe($"  closed {e.Result}");
        owner.Unloaded += OnUnloaded;
        try
        {
            dialog.XamlRoot = root;
            var result = await dialog.ShowAsync();
            Probe($"  returned {result}");
            return result;
        }
        catch (COMException e)
        {
            Probe($"  COMException {e.HResult:X8} {e.Message}");
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
