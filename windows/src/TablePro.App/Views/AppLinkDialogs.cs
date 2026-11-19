using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using TablePro.App.Services;

namespace TablePro.App.Views;

// A tablepro://connect link's questions, as macOS asks them; each waits for the window and any open dialog.
internal static class AppLinkDialogs
{
    // macOS previews this much of a link's SQL.
    private const int PreviewCharacters = 300;

    // Return and Escape cancel: a link can come from any web page.
    public static async Task<bool> ConfirmQueryAsync(FrameworkElement owner, string connection, string sql)
    {
        ArgumentNullException.ThrowIfNull(owner);
        ArgumentNullException.ThrowIfNull(sql);
        var content = new StackPanel { Spacing = 12 };
        content.Children.Add(new TextBlock
        {
            Text = Strings.Format("LinkQueryMessage", connection),
            TextWrapping = TextWrapping.Wrap,
        });
        var preview = new TextBlock
        {
            Text = sql.Length > PreviewCharacters ? string.Concat(sql.AsSpan(0, PreviewCharacters), "…") : sql,
            FontFamily = new FontFamily("Cascadia Mono, Consolas, Courier New"),
            TextWrapping = TextWrapping.Wrap,
            IsTextSelectionEnabled = true,
        };
        AutomationProperties.SetAutomationId(preview, "LinkQueryPreview");
        content.Children.Add(preview);
        var dialog = new ContentDialog
        {
            RequestedTheme = owner.ActualTheme,
            Title = Strings.Get("LinkQueryTitle"),
            Content = new ScrollViewer { Content = content, MaxHeight = 480 },
            PrimaryButtonText = Strings.Get("LinkQueryOpen"),
            CloseButtonText = Strings.Get("Cancel"),
            DefaultButton = ContentDialogButton.Close,
        };
        return await WindowDialogs.ShowWhenFreeAsync(dialog, owner).ConfigureAwait(true) == ContentDialogResult.Primary;
    }

    public static Task TellConnectionFailedAsync(FrameworkElement owner, string message)
    {
        ArgumentNullException.ThrowIfNull(owner);
        return WindowDialogs.ShowWhenFreeAsync(
            new ContentDialog
            {
                RequestedTheme = owner.ActualTheme,
                Title = Strings.Get("LinkConnectionFailedTitle"),
                Content = new TextBlock { Text = message, TextWrapping = TextWrapping.Wrap },
                CloseButtonText = Strings.Get("Close"),
                DefaultButton = ContentDialogButton.Close,
            },
            owner);
    }
}
