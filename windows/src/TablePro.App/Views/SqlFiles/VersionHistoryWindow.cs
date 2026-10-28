using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using TablePro.App.Helpers;
using TablePro.App.Services;
using TablePro.Storage.Library.History;

namespace TablePro.App.Views.SqlFiles;

/// <summary>
/// A file's version history in its own window, beside the workspace, so the diff gets the room a side pane cannot
/// give it. One window per file: asking again for the same file brings its window forward.
/// </summary>
internal sealed partial class VersionHistoryWindow : Window
{
    private static readonly Dictionary<string, VersionHistoryWindow> Open = new(StringComparer.OrdinalIgnoreCase);

    private readonly VersionHistoryView _view;

    private VersionHistoryWindow(string path, IVersionHistoryProvider provider, BackdropKind backdrop, ElementTheme theme, Action<string> openInEditor, Action restored)
    {
        Title = Path.GetFileName(path) + " History - TablePro";
        var titleBar = new Grid { Height = 48, Padding = new Thickness(16, 0, 140, 0) };
        titleBar.Children.Add(new TextBlock
        {
            Text = Path.GetFileName(path) + " History",
            VerticalAlignment = VerticalAlignment.Center,
            Style = (Style)Application.Current.Resources["CaptionTextBlockStyle"],
        });

        _view = new VersionHistoryView(new VersionHistoryBrowser(provider), new DialogService(this), openInEditor, restored);
        var root = new Grid();
        root.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        root.RowDefinitions.Add(new RowDefinition { Height = new GridLength(1, GridUnitType.Star) });
        root.Children.Add(titleBar);
        Grid.SetRow(_view, 1);
        root.Children.Add(_view);
        Content = root;
        WindowChrome.Apply(this, titleBar, backdrop, theme, 1100, 720);
    }

    /// <summary>Opens the history of <paramref name="path"/>, or brings forward the window already showing it.</summary>
    public static void Show(string path, IVersionHistoryProvider provider, BackdropKind backdrop, ElementTheme theme, Action<string> openInEditor, Action restored)
    {
        var key = Path.GetFullPath(path);
        if (Open.TryGetValue(key, out var existing))
        {
            _ = existing._view.RefreshAsync();
            existing.Activate();
            return;
        }

        var window = new VersionHistoryWindow(key, provider, backdrop, theme, openInEditor, restored);
        Open[key] = window;
        window.Closed += (_, _) => Open.Remove(key);
        window.Activate();
    }
}
