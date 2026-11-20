using System.Globalization;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using TablePro.App.Model;
using TablePro.App.Services;
using Windows.System;

namespace TablePro.App.Views;

// Software update: what the last check found, its action, the channel, and the running version's notes.
public sealed partial class SettingsView
{
    // Called while _loading is set, so nothing here writes the settings back.
    private void LoadUpdates()
    {
        var channel = Updater.ChannelFor(_workbench.Settings.UpdateChannel);
        UpdateChannelBox.SelectedIndex = channel == UpdateChannel.Beta ? 1 : 0;
        ShowUpdateState();
    }

    // The Help menu's Check for updates: the section in view, and a check unless one is running or found something.
    public void ShowUpdates(bool check)
    {
        UpdatesHeader.StartBringIntoView();
        if (check && _workbench.Updates.State is UpdateState.NotChecked or UpdateState.Current or UpdateState.Failed)
        {
            _ = _workbench.Updates.CheckAsync(_workbench.Settings.UpdateChannel);
        }
    }

    private void OnUpdatesChanged(object? sender, EventArgs e) => ShowUpdateState();

    private void ShowUpdateState()
    {
        var current = Strings.Format("UpdateVersion", AppStorage.Version);
        (string Header, string Description, string? Action, bool Busy) shown = _workbench.Updates.State switch
        {
            UpdateState.Unsupported => (current, Strings.Get("UpdateUnsupported"), null, false),
            UpdateState.Checking => (current, Strings.Get("UpdateChecking"), Strings.Get("UpdateCheckButton"), true),
            UpdateState.Current state => (current, LastChecked(state.CheckedAt), Strings.Get("UpdateCheckButton"), false),
            UpdateState.Available state => (
                Strings.Format("UpdateAvailableHeadline", state.Version),
                LastChecked(state.CheckedAt),
                Strings.Get("UpdateInstallButton"),
                false),
            UpdateState.Installing state => (
                Strings.Format("UpdateInstallingHeadline", state.Version),
                Strings.Format("UpdateInstallingDetail", state.Percent),
                null,
                true),
            UpdateState.ReadyToRestart state => (
                Strings.Format("UpdateReadyHeadline", state.Version),
                Strings.Get("UpdateRestartToFinish"),
                null,
                false),
            UpdateState.Failed state => (current, state.Reason, Strings.Get("UpdateCheckButton"), false),
            _ => (current, Strings.Get("UpdateNeverChecked"), Strings.Get("UpdateCheckButton"), false),
        };
        UpdateCard.Header = shown.Header;
        UpdateCard.Description = shown.Description;
        UpdateProgress.IsActive = shown.Busy;
        UpdateProgress.Visibility = shown.Busy ? Visibility.Visible : Visibility.Collapsed;
        UpdateButton.Content = shown.Action;
        UpdateButton.Visibility = shown.Action is null ? Visibility.Collapsed : Visibility.Visible;
        UpdateButton.IsEnabled = _workbench.Updates.State is not UpdateState.Checking;
    }

    private static string LastChecked(DateTimeOffset at) => Strings.Format(
        "UpdateLastChecked",
        at.ToLocalTime().ToString("g", CultureInfo.CurrentCulture));

    private async void OnUpdateButton(object sender, RoutedEventArgs e)
    {
        if (_workbench.Updates.State is UpdateState.Available)
        {
            await _shell.InstallUpdateAsync();
            return;
        }

        await _workbench.Updates.CheckAsync(_workbench.Settings.UpdateChannel);
    }

    private async void OnUpdateChannelChanged(object sender, SelectionChangedEventArgs e)
    {
        if (_loading || UpdateChannelBox.SelectedItem is not ComboBoxItem { Tag: string tag })
        {
            return;
        }

        var channel = Enum.Parse<UpdateChannel>(tag);
        _workbench.UpdateSettings(settings => settings with { UpdateChannel = channel });
        await _workbench.Updates.CheckAsync(channel);
    }

    private async void OnWhatsNew(object sender, RoutedEventArgs e) =>
        await Launcher.LaunchUriAsync(Updater.ReleaseNotes(AppStorage.Version));
}
