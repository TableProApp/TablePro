using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using TablePro.App.Services;
using TablePro.Interop;

namespace TablePro.App.Views;

// An MCP client's write, asked about over the connection it runs on, as the Linux app asks it; Enter cancels.
public sealed partial class WorkspaceView
{
    internal async Task<bool> ConfirmClientWriteAsync(McpWriteRequest request, string connection, CancellationToken withdrawn)
    {
        ArgumentNullException.ThrowIfNull(request);
        var content = new StackPanel { Spacing = 12 };
        content.Children.Add(new TextBlock
        {
            Text = Strings.Format(request.Destructive ? "ClientWriteDestructive" : "ClientWriteMessage", connection),
            TextWrapping = TextWrapping.Wrap,
        });
        var statement = new TextBlock
        {
            Text = request.Sql,
            FontFamily = new FontFamily("Cascadia Mono, Consolas, Courier New"),
            TextWrapping = TextWrapping.Wrap,
            IsTextSelectionEnabled = true,
        };
        AutomationProperties.SetAutomationId(statement, "ClientWriteStatement");
        content.Children.Add(statement);
        var dialog = new ContentDialog
        {
            Title = Strings.Get("ClientWriteTitle"),
            Content = new ScrollViewer { Content = content, MaxHeight = 480 },
            PrimaryButtonText = Strings.Get("ClientWriteRun"),
            CloseButtonText = Strings.Get("Cancel"),
            DefaultButton = ContentDialogButton.Close,
            RequestedTheme = ActualTheme,
        };
        AutomationProperties.SetAutomationId(dialog, "ClientWriteDialog");
        // The client went away, so its question comes down; the core reads that as declined.
        using var registration = withdrawn.Register(() => DispatcherQueue.TryEnqueue(dialog.Hide));
        return await WindowDialogs.ShowWhenFreeAsync(dialog, this, withdrawn).ConfigureAwait(true)
            == ContentDialogResult.Primary;
    }
}
