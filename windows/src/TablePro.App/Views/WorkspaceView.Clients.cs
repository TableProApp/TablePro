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
        // A question waiting its turn is declined once the workspace leaves the window, as a shown one is.
        using var ended = CancellationTokenSource.CreateLinkedTokenSource(withdrawn);
        void OnUnloaded(object sender, RoutedEventArgs args) => ended.Cancel();
        Unloaded += OnUnloaded;
        using var registration = ended.Token.Register(() => DispatcherQueue.TryEnqueue(dialog.Hide));
        try
        {
            return await WindowDialogs.ShowWhenFreeAsync(dialog, this, ended.Token).ConfigureAwait(true)
                == ContentDialogResult.Primary;
        }
        finally
        {
            Unloaded -= OnUnloaded;
        }
    }
}
