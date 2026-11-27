using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using TablePro.App.Model;
using TablePro.App.Services;
using Windows.System;

namespace TablePro.App;

// Updates: the Help menu's check, the primary's bar that offers an update or says one arrived, and the restart.
public sealed partial class MainWindow
{
    private UpdateBarShows _updateBar;
    private bool _updateOfferDismissed;

    private enum UpdateBarShows
    {
        Nothing,
        Offer,
        Updated,
    }

    // As often as the macOS app's Sparkle checks; Windows itself checks a release install at launch and every 8 hours.
    private static readonly TimeSpan CheckEvery = TimeSpan.FromHours(24);

    // The primary's alone, once its window is up; a build that is not installed has nothing to check.
    internal void StartUpdates()
    {
        if (!AppStorage.IsPackaged)
        {
            return;
        }

        NoteLaunch();
        _ = _workbench.Updates.CheckAsync(_workbench.Settings.UpdateChannel);
        var timer = DispatcherQueue.CreateTimer();
        timer.Interval = CheckEvery;
        timer.IsRepeating = true;
        timer.Tick += async (_, _) =>
        {
            if (_workbench.Updates.State is UpdateState.NotChecked or UpdateState.Current or UpdateState.Failed)
            {
                await _workbench.Updates.CheckAsync(_workbench.Settings.UpdateChannel);
            }
        };
        timer.Start();
        Closed += (_, _) => timer.Stop();
    }

    // As the macOS app quits for Sparkle: Exit's questions and shutdown first, so a stopped run or a discarded edit
    // stays that way, then Windows installs and Restart Manager starts the new version.
    public async Task InstallUpdateAsync()
    {
        if (!IsPrimary)
        {
            _primary.Activate();
            await _primary.InstallUpdateAsync();
            return;
        }

        if (_workbench.Updates.State is not UpdateState.Available available
            || _checkingClose
            || _closing
            || AllWindows.Any(window => WindowDialogs.IsOpen(window.Content.XamlRoot)))
        {
            return;
        }

        var dialog = new ContentDialog
        {
            XamlRoot = Root.XamlRoot,
            RequestedTheme = Root.ActualTheme,
            Title = Strings.Format("UpdateInstallTitle", available.Version),
            Content = new TextBlock { Text = Strings.Get("UpdateInstallMessage"), TextWrapping = TextWrapping.Wrap },
            PrimaryButtonText = Strings.Get("UpdateRestartButton"),
            CloseButtonText = Strings.Get("Cancel"),
            DefaultButton = ContentDialogButton.Primary,
        };
        if (await WindowDialogs.ShowAsync(dialog, Root) == ContentDialogResult.Primary)
        {
            await RequestCloseAsync(askAboutRunning: true, afterShutDown: InstallAfterShutDownAsync);
        }
    }

    // A deployment that returns has failed or left the new version for the next start; either way the app starts again.
    private async Task InstallAfterShutDownAsync()
    {
        await _workbench.Updates.InstallAsync();
        if (_workbench.Updates.State is UpdateState.Failed failed)
        {
            AppWindow.Show();
            var dialog = new ContentDialog
            {
                XamlRoot = Root.XamlRoot,
                RequestedTheme = Root.ActualTheme,
                Title = Strings.Get("UpdateInstallFailedTitle"),
                Content = new TextBlock { Text = failed.Reason, TextWrapping = TextWrapping.Wrap },
                CloseButtonText = Strings.Get("UpdateRestartButton"),
            };
            await WindowDialogs.ShowAsync(dialog, Root);
        }

        var refused = Microsoft.Windows.AppLifecycle.AppInstance.Restart(string.Empty);
        CrashLog.Write(new InvalidOperationException($"The app did not restart after an update: {refused}."));
    }

    private void WatchUpdates()
    {
        _workbench.Updates.Changed += OnUpdatesChanged;
        Closed += (_, _) => _workbench.Updates.Changed -= OnUpdatesChanged;
        ShowUpdates();
    }

    // As the Linux app's launch notice: the first start of a newer version says so, and an older one records nothing.
    private void NoteLaunch()
    {
        var current = Updater.PackageVersion();
        var kind = LaunchHistory.After(_workbench.Settings.LastLaunchedVersion, current);
        if (!LaunchHistory.Records(kind))
        {
            return;
        }

        _workbench.UpdateSettings(settings => settings with { LastLaunchedVersion = current.ToString() });
        if (kind == LaunchKind.Update)
        {
            ShowUpdateBar(
                UpdateBarShows.Updated,
                InfoBarSeverity.Success,
                Strings.Format("UpdatedMessage", AppStorage.Version),
                Strings.Get("WhatsNewButton"));
        }
    }

    private void OnUpdatesChanged(object? sender, EventArgs e) => ShowUpdates();

    private void ShowUpdates()
    {
        var state = _workbench.Updates.State;
        MenuCheckForUpdates.Text = Strings.Get(
            state is UpdateState.Available ? "MenuUpdateAvailable" : "MenuCheckForUpdates");
        if (!IsPrimary || _updateBar == UpdateBarShows.Updated)
        {
            return;
        }

        switch (state)
        {
            case UpdateState.Available available when !_updateOfferDismissed:
                ShowUpdateBar(
                    UpdateBarShows.Offer,
                    InfoBarSeverity.Informational,
                    Strings.Format("UpdateAvailableMessage", available.Version),
                    Strings.Get("UpdateInstallButton"));
                break;
            case UpdateState.Installing installing when _updateBar == UpdateBarShows.Offer:
                ShowUpdateBar(
                    UpdateBarShows.Offer,
                    InfoBarSeverity.Informational,
                    Strings.Format("UpdateInstallingDetail", installing.Percent / 100.0),
                    null);
                break;
            case UpdateState.Failed failed when _updateBar == UpdateBarShows.Offer:
                ShowUpdateBar(UpdateBarShows.Offer, InfoBarSeverity.Error, failed.Reason, null);
                break;
            default:
                if (_updateBar == UpdateBarShows.Offer)
                {
                    HideUpdateBar();
                }

                break;
        }
    }

    private void ShowUpdateBar(UpdateBarShows shows, InfoBarSeverity severity, string message, string? action)
    {
        _updateBar = shows;
        Button? button = null;
        if (action is not null)
        {
            button = new Button { Content = action };
            Microsoft.UI.Xaml.Automation.AutomationProperties.SetAutomationId(button, "UpdateBarButton");
            button.Click += OnUpdateBarAction;
        }

        UpdateBar.Severity = severity;
        UpdateBar.Message = message;
        UpdateBar.ActionButton = button;
        UpdateBar.IsOpen = true;
    }

    private void HideUpdateBar()
    {
        _updateBar = UpdateBarShows.Nothing;
        UpdateBar.IsOpen = false;
    }

    private async void OnUpdateBarAction(object sender, RoutedEventArgs e)
    {
        if (_updateBar == UpdateBarShows.Updated)
        {
            HideUpdateBar();
            ShowUpdates();
            await Launcher.LaunchUriAsync(Updater.ReleaseNotes(AppStorage.Version));
            return;
        }

        await InstallUpdateAsync();
    }

    // Closed by the user, the offer stays away for this launch; the Help menu and Settings still show it.
    private void OnUpdateBarClosed(InfoBar sender, InfoBarClosedEventArgs args)
    {
        if (args.Reason != InfoBarCloseReason.CloseButton)
        {
            return;
        }

        if (_updateBar == UpdateBarShows.Offer)
        {
            _updateOfferDismissed = true;
        }

        var was = _updateBar;
        _updateBar = UpdateBarShows.Nothing;
        if (was == UpdateBarShows.Updated)
        {
            ShowUpdates();
        }
    }

    private void OnCheckForUpdates(object sender, RoutedEventArgs e)
    {
        ShowSettings();
        _primary.Settings().ShowUpdates(check: true);
    }
}
