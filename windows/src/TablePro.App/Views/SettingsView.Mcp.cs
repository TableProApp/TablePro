using System.Globalization;
using System.Runtime.InteropServices;
using CommunityToolkit.WinUI.Controls;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using TablePro.App.Services;
using TablePro.Interop;
using Windows.ApplicationModel.DataTransfer;

namespace TablePro.App.Views;

// The MCP section: the server's switch, status and port, what a client needs to reach it, and the clients it saw.
public sealed partial class SettingsView
{
    // Called while _loading is set, so nothing here writes the settings back.
    private void LoadMcp()
    {
        var settings = _workbench.Settings;
        McpServerSwitch.IsOn = settings.McpServerEnabled;
        McpPortBox.Value = settings.McpServerPort;
        ShowMcp();
    }

    private void OnMcpChanged(object? sender, EventArgs e) => ShowMcp();

    private void ShowMcp()
    {
        var status = _workbench.McpStatus;
        McpStatusCard.Description = StatusText(status);
        McpRetryButton.Visibility = status.State == McpServerState.Failed ? Visibility.Visible : Visibility.Collapsed;
        McpAddressCard.Description = McpServer.Address(_workbench.Settings.McpServerPort);
        ShowClients(_workbench.McpClients);
    }

    private static string StatusText(McpServerStatus status) => status.State switch
    {
        McpServerState.Starting => Strings.Get("McpStatusStarting"),
        McpServerState.Running => Strings.Format("McpStatusRunning", status.Port),
        McpServerState.Failed => FailureText(status),
        _ => Strings.Get("McpStatusOff"),
    };

    // A secret.* code is Credential Manager's, worded as the connections' passwords are.
    private static string FailureText(McpServerStatus status) => status.Failure is not { } failure
        ? Strings.Get("McpFailureInterrupted")
        : failure.Code switch
        {
            "mcp.port_in_use" => Strings.Format("McpFailurePortInUse", status.Port),
            "mcp.listen_failed" => Strings.Format("McpFailureListen", status.Port),
            "mcp.no_randomness" => Strings.Get("McpFailureNoRandomness"),
            "mcp.interrupted" => Strings.Get("McpFailureInterrupted"),
            _ => Strings.Format("McpFailureToken", Strings.Error(failure)),
        };

    private void ShowClients(IReadOnlyList<McpClientSighting> clients)
    {
        McpClientsExpander.Items.Clear();
        McpClientsExpander.Description = Strings.Get(clients.Count == 0 ? "McpClientsNone" : "McpClientsSeen");
        foreach (var client in clients.Reverse())
        {
            McpClientsExpander.Items.Add(new SettingsCard
            {
                Header = client.Title ?? client.Name,
                Description = Strings.Format(
                    "McpClientSeen",
                    client.Version,
                    client.SeenAt.ToLocalTime().ToString("t", CultureInfo.CurrentCulture)),
            });
        }
    }

    private void OnMcpServerToggled(object sender, RoutedEventArgs e)
    {
        if (!_loading)
        {
            var enabled = McpServerSwitch.IsOn;
            _workbench.UpdateSettings(settings => settings with { McpServerEnabled = enabled });
        }
    }

    private void OnMcpPortChanged(NumberBox sender, NumberBoxValueChangedEventArgs args)
    {
        if (!_loading && !double.IsNaN(args.NewValue))
        {
            _workbench.UpdateSettings(settings => settings with { McpServerPort = (int)args.NewValue });
            McpAddressCard.Description = McpServer.Address(_workbench.Settings.McpServerPort);
        }
    }

    private void OnMcpRetry(object sender, RoutedEventArgs e) => _workbench.ApplyMcpSettings();

    private void OnCopyMcpAddress(object sender, RoutedEventArgs e) =>
        CopyMcp(McpServer.Address(_workbench.Settings.McpServerPort), "McpAddressCopied");

    // The token is read only to be copied, never shown on the page.
    private async void OnCopyMcpHeader(object sender, RoutedEventArgs e)
    {
        McpCopyHeaderButton.IsEnabled = false;
        try
        {
            var token = await _workbench.GetMcpTokenAsync().ConfigureAwait(true);
            CopyMcp("Bearer " + token, "McpHeaderCopied");
        }
        catch (TableProException exception)
        {
            McpNoteText.Text = Strings.Format("McpFailureToken", Strings.Error(exception.Error));
        }
        catch (InvalidOperationException)
        {
            McpNoteText.Text = Strings.Get("McpFailureInterrupted");
        }
        finally
        {
            McpCopyHeaderButton.IsEnabled = true;
        }
    }

    // Every client set up with the old token is refused from its next request, so it asks first and Cancel is the default.
    private async void OnRegenerateMcpToken(object sender, RoutedEventArgs e)
    {
        var dialog = new ContentDialog
        {
            XamlRoot = XamlRoot,
            RequestedTheme = ActualTheme,
            Title = Strings.Get("McpRegenerateTitle"),
            Content = Strings.Get("McpRegenerateMessage"),
            PrimaryButtonText = Strings.Get("McpRegenerateConfirm"),
            CloseButtonText = Strings.Get("Cancel"),
            DefaultButton = ContentDialogButton.Close,
        };
        if (await WindowDialogs.ShowAsync(dialog, this).ConfigureAwait(true) != ContentDialogResult.Primary)
        {
            return;
        }

        McpRegenerateButton.IsEnabled = false;
        try
        {
            await _workbench.RegenerateMcpTokenAsync().ConfigureAwait(true);
            McpNoteText.Text = Strings.Get("McpRegenerated");
        }
        catch (TableProException exception)
        {
            McpNoteText.Text = Strings.Format("McpFailureToken", Strings.Error(exception.Error));
        }
        finally
        {
            McpRegenerateButton.IsEnabled = true;
        }
    }

    private void CopyMcp(string text, string done)
    {
        var package = new DataPackage();
        package.SetText(text);
        try
        {
            Clipboard.SetContent(package);
            Clipboard.Flush();
            McpNoteText.Text = Strings.Get(done);
        }
        catch (COMException)
        {
            McpNoteText.Text = Strings.Get("McpCopyFailed");
        }
    }
}
