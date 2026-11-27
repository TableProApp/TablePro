using System.Diagnostics;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using TablePro.App.Model;
using TablePro.App.Services;
using Windows.System;

namespace TablePro.App;

// The license ask and the paid-feature gate (docs/decisions/0023-license-ask-and-paid-feature-gate.md). The primary
// counts the days of use and keeps the window in use; the ask shows on that window.
public sealed partial class MainWindow
{
    // The UI tests set it so the ask does not wait out its five minutes.
    private const string AskQuietVariable = "TABLEPRO_LICENSE_ASK_QUIET_SECONDS";

    // A day that turns while a window stays in front still counts, within this.
    private static readonly TimeSpan AskLooksEvery = TimeSpan.FromHours(1);

    private long? _launchedAt;
    private TimeSpan _askQuietPeriod = LicenseAsk.LaunchQuietPeriod;
    private MainWindow? _windowInUse;

    private static DateOnly Today => DateOnly.FromDateTime(DateTime.Now);

    // The primary's alone, once its window is up.
    internal void StartLicenseAsk()
    {
        _launchedAt = Stopwatch.GetTimestamp();
        _askQuietPeriod = LicenseAsk.QuietPeriod(Environment.GetEnvironmentVariable(AskQuietVariable));
        RecordUse();
        var timer = DispatcherQueue.CreateTimer();
        timer.IsRepeating = false;
        timer.Interval = _askQuietPeriod;
        timer.Tick += OnAskTimer;
        timer.Start();
        _workbench.AccountChanged += OnAccountKnown;
        Closed += (_, _) =>
        {
            timer.Stop();
            _workbench.AccountChanged -= OnAccountKnown;
        };
    }

    private void OnAskTimer(Microsoft.UI.Dispatching.DispatcherQueueTimer timer, object args)
    {
        if (_windowInUse is not null)
        {
            RecordUse();
        }

        AskIfDue();
        timer.Interval = AskLooksEvery;
        timer.Start();
    }

    // Whether a license is held is known only once the account has read its file; one found later ends the ask.
    private void OnAccountKnown(object? sender, EventArgs e)
    {
        if (_workbench.HasLicense is true)
        {
            foreach (var window in AllWindows)
            {
                window.LicenseAskBar.IsOpen = false;
            }

            return;
        }

        AskIfDue();
    }

    private void NoteActivation(MainWindow window, bool active)
    {
        if (!active)
        {
            if (ReferenceEquals(_windowInUse, window))
            {
                _windowInUse = null;
            }

            return;
        }

        _windowInUse = window;
        if (_launchedAt is not null)
        {
            RecordUse();
            AskIfDue();
        }
    }

    private void RecordUse() => _workbench.UpdateSettings(settings => LicenseAsk.RecordUse(settings, Today));

    private bool IsBusy => _open.Any(open => open.View.IsBusy);

    // Each check is cheap, and the first that fails ends the look.
    private void AskIfDue()
    {
        if (_launchedAt is not { } launched
            || _closing
            || _checkingClose
            || _windowInUse is not { _isSpare: false } window
            || !window.AppWindow.IsVisible
            || _workbench.HasLicense is not false
            || !LicenseAsk.IsDue(_workbench.Settings, hasLicense: false, Today)
            || !LicenseAsk.IsQuietMoment(
                Stopwatch.GetElapsedTime(launched), _askQuietPeriod, AllWindows.Any(each => each.IsBusy))
            || AllWindows.Any(each => WindowDialogs.IsOpen(each.Content.XamlRoot)))
        {
            return;
        }

        _workbench.UpdateSettings(settings => LicenseAsk.Asked(settings, Today));
        window.ShowLicenseAsk(_workbench.Settings.UsageDays);
    }

    private void ShowLicenseAsk(int days)
    {
        LicenseAskBar.Title = Strings.Plural("LicenseAskTitle", days, days);
        LicenseAskBar.Message = Strings.Get("LicenseAskMessage");
        LicenseAskBar.IsOpen = true;
    }

    private async void OnLicenseAskBuy(object sender, RoutedEventArgs e)
    {
        AnswerLicenseAsk(LicenseAskAnswer.Buy);
        await Launcher.LaunchUriAsync(AccountSetup.Pricing("app-ask"));
    }

    private void OnLicenseAskPersonal(object sender, RoutedEventArgs e) => AnswerLicenseAsk(LicenseAskAnswer.Personal);

    // The close button is Not now; the app's own close follows an answer already kept.
    private void OnLicenseAskClosed(InfoBar sender, InfoBarClosedEventArgs args)
    {
        if (args.Reason == InfoBarCloseReason.CloseButton)
        {
            _workbench.UpdateSettings(settings => settings with { LicenseAskAnswer = LicenseAskAnswer.NotNow });
        }
    }

    private void AnswerLicenseAsk(LicenseAskAnswer answer)
    {
        _workbench.UpdateSettings(settings => settings with { LicenseAskAnswer = answer });
        LicenseAskBar.IsOpen = false;
    }

    // The gate a paid command asks before it runs: false once it showed what the feature needs, as the macOS app's
    // license alert does. A pane shows Workbench.Gate's notice in place instead.
    internal async Task<bool> RequirePlanAsync(string feature)
    {
        if (_workbench.Gate(feature) is not { } notice)
        {
            return true;
        }

        var dialog = new ContentDialog
        {
            XamlRoot = Root.XamlRoot,
            RequestedTheme = Root.ActualTheme,
            Title = LicenseText.Title(notice, feature),
            Content = new TextBlock { Text = LicenseText.Message(notice, feature), TextWrapping = TextWrapping.Wrap },
            PrimaryButtonText = LicenseText.Action(notice.Action),
            SecondaryButtonText = notice.Alternative is { } alternative ? LicenseText.Action(alternative) : string.Empty,
            CloseButtonText = Strings.Get("Cancel"),
            DefaultButton = ContentDialogButton.Primary,
        };
        AutomationProperties.SetAutomationId(dialog, "LicenseGateDialog");
        LicenseAction? chosen = await WindowDialogs.ShowAsync(dialog, Root) switch
        {
            ContentDialogResult.Primary => notice.Action,
            ContentDialogResult.Secondary => notice.Alternative,
            _ => null,
        };
        if (chosen is { } action)
        {
            await PerformLicenseActionAsync(action, PlanFeatures.GateReferrer(feature));
        }

        return false;
    }

    // As the macOS app's notice actions: the account's own steps run in Settings, where their outcome shows.
    private async Task PerformLicenseActionAsync(LicenseAction action, string referrer)
    {
        if (action is LicenseAction.Purchase or LicenseAction.Upgrade)
        {
            await Launcher.LaunchUriAsync(AccountSetup.Pricing(referrer));
            return;
        }

        ShowSettings();
        var settings = _primary.Settings();
        switch (action)
        {
            case LicenseAction.SignIn:
                await settings.SignInAsync();
                break;
            case LicenseAction.TryAgain:
                await settings.RefreshAccountAsync();
                break;
            default:
                settings.ShowAccountSection();
                break;
        }
    }
}
