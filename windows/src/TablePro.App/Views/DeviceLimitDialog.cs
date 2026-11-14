using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using TablePro.App.Model;
using TablePro.App.Services;
using TablePro.Interop;

namespace TablePro.App.Views;

// The license is in use on as many devices as it allows: one is removed here, which asks the account again.
internal static class DeviceLimitDialog
{
    public static async Task ShowAsync(FrameworkElement owner, Workbench workbench, IReadOnlyList<AccountDevice> devices)
    {
        ArgumentNullException.ThrowIfNull(owner);
        ArgumentNullException.ThrowIfNull(workbench);
        ArgumentNullException.ThrowIfNull(devices);
        var error = new InfoBar { Severity = InfoBarSeverity.Error, IsClosable = false, Visibility = Visibility.Collapsed };
        var list = new StackPanel { Spacing = 8 };
        var content = new StackPanel { Spacing = 12 };
        content.Children.Add(new TextBlock { Text = Strings.Get("DeviceLimitMessage"), TextWrapping = TextWrapping.Wrap });
        content.Children.Add(error);
        content.Children.Add(list);
        var dialog = new ContentDialog
        {
            RequestedTheme = owner.ActualTheme,
            Title = Strings.Get("DeviceLimitTitle"),
            Content = new ScrollViewer { Content = content, MaxHeight = 480 },
            CloseButtonText = Strings.Get("Cancel"),
            DefaultButton = ContentDialogButton.Close,
        };
        AutomationProperties.SetAutomationId(list, "DeviceLimitList");
        void Show(InfoBarSeverity severity, string message)
        {
            error.Severity = severity;
            error.Message = message;
            error.Visibility = Visibility.Visible;
            error.IsOpen = true;
        }

        foreach (var device in AccountDevices.Ordered(devices))
        {
            list.Children.Add(Row(device, async (row, button) =>
            {
                if (await workbench.GetAccountAsync().ConfigureAwait(true) is not { } account)
                {
                    return;
                }

                button.IsEnabled = false;
                error.Visibility = Visibility.Collapsed;
                error.IsOpen = false;
                TableProException? failure = null;
                IReadOnlyList<AccountDevice>? listed = null;
                try
                {
                    // The core asks the account again after a removal, so no refresh is asked here.
                    await account.RemoveDeviceAsync(device.Id).ConfigureAwait(true);
                }
                catch (TableProException exception)
                {
                    failure = exception;
                    try
                    {
                        listed = await account.GetDevicesAsync().ConfigureAwait(true);
                    }
                    catch (TableProException)
                    {
                        // Unknown, so the device counts as still there.
                    }
                }

                var status = account.Status;
                workbench.ShowAccount(status);
                switch (AccountDevices.Removal(failure is null, listed, device.Id))
                {
                    case DeviceRemoval.NotRemoved:
                        button.IsEnabled = true;
                        Show(InfoBarSeverity.Error, Strings.Error(failure!.Error));
                        break;
                    case DeviceRemoval.RemovedNotRefreshed:
                        list.Children.Remove(row);
                        var reason = Strings.Error(failure!.Error);
                        Show(InfoBarSeverity.Warning, Strings.Format("DeviceRemovedNotRefreshed", device.Name, reason));
                        break;
                    default:
                        list.Children.Remove(row);
                        if (!AccountDevices.PastLimit(status))
                        {
                            dialog.Hide();
                        }

                        break;
                }
            }));
        }

        await WindowDialogs.ShowAsync(dialog, owner).ConfigureAwait(true);
    }

    private static Grid Row(AccountDevice device, Func<Grid, Button, Task> remove)
    {
        var row = new Grid { ColumnSpacing = 12 };
        row.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        row.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        var text = new StackPanel();
        text.Children.Add(new TextBlock { Text = device.Name, TextTrimming = TextTrimming.CharacterEllipsis });
        text.Children.Add(new TextBlock
        {
            Text = DeviceText(device),
            Style = (Style)Application.Current.Resources["CaptionTextBlockStyle"],
            TextWrapping = TextWrapping.Wrap,
        });
        row.Children.Add(text);
        var button = new Button
        {
            Content = Strings.Get("DeviceRemove"),
            VerticalAlignment = VerticalAlignment.Center,
            IsEnabled = AccountDevices.CanRemove(device, DateTimeOffset.Now),
        };
        AutomationProperties.SetName(button, Strings.Format("DeviceRemoveName", device.Name));
        button.Click += async (_, _) => await remove(row, button).ConfigureAwait(true);
        Grid.SetColumn(button, 1);
        row.Children.Add(button);
        return row;
    }

    // "This computer", or the platform and when it was last seen; an offline file says until when it holds.
    public static string DeviceText(AccountDevice device)
    {
        ArgumentNullException.ThrowIfNull(device);
        if (device.IsThisMachine)
        {
            return Strings.Get("DeviceThisComputer");
        }

        var platform = Strings.Get("DevicePlatform_" + device.Platform) is { Length: > 0 } named ? named : device.Platform;
        return device.OfflineUntil is { } until && until > DateTimeOffset.Now
            ? Strings.Format("DeviceOfflineUntil", platform, until.LocalDateTime)
            : Strings.Format("DeviceLastSeen", platform, device.LastSeenAt.LocalDateTime);
    }
}
