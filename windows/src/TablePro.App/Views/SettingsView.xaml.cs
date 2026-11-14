using CommunityToolkit.WinUI.Controls;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using TablePro.App.Model;
using TablePro.App.Services;
using TablePro.Editor;
using TablePro.Interop;
using Windows.System;

namespace TablePro.App.Views;

// Settings apply as they change, as the Windows settings guidance has them; there is no Save.
public sealed partial class SettingsView : UserControl
{
    public static readonly Uri DocumentationUri = new("https://docs.tablepro.app");
    public static readonly Uri IssuesUri = new("https://github.com/TableProApp/TablePro/issues/new/choose");

    private readonly Workbench _workbench;
    private bool _loading;
    private bool _accountBusy;
    private CoreError? _accountError;
    private int _devicesGeneration;

    internal SettingsView(Workbench workbench)
    {
        _workbench = workbench;
        InitializeComponent();
        VersionText.Text = Strings.Format("VersionText", AppStorage.Version);
        DataFolderCard.Description = workbench.Folder;
        Load();
        ShowAccount();
        // The workbench outlives the page only while the window is open, so the page listens while it is shown.
        Loaded += (_, _) =>
        {
            _workbench.AccountChanged -= OnAccountChanged;
            _workbench.AccountChanged += OnAccountChanged;
            ShowAccount();
        };
        Unloaded += (_, _) => _workbench.AccountChanged -= OnAccountChanged;
    }

    public void ShowAbout()
    {
        AboutExpander.IsExpanded = true;
        AboutExpander.StartBringIntoView();
    }

    private void Load()
    {
        _loading = true;
        var settings = _workbench.Settings;
        ThemeBox.SelectedIndex = settings.Theme switch
        {
            AppTheme.Light => 0,
            AppTheme.Dark => 1,
            _ => 2,
        };
        ReopenSwitch.IsOn = settings.ReopenSession;
        FontSizeBox.Value = settings.EditorFontSize;
        RowLimitBox.Value = settings.RowLimit;
        TimeoutBox.Value = settings.QueryTimeoutSeconds;
        // A size the file holds that the list does not offer is shown too, so the box never reads empty.
        PageSizeBox.Items.Clear();
        foreach (var size in AppSettings.PageSizeChoices.Append(settings.PageSize).Distinct().Order())
        {
            PageSizeBox.Items.Add(new ComboBoxItem { Content = Strings.Format("PageSizeOption", size), Tag = size });
        }

        PageSizeBox.SelectedItem = PageSizeBox.Items
            .OfType<ComboBoxItem>()
            .First(item => item.Tag is int size && size == settings.PageSize);
        ResultsKeptBox.Items.Clear();
        foreach (var kept in AppSettings.ResultsKeptChoices.Append(settings.ResultSetsKeptPerRun).Distinct().Order())
        {
            ResultsKeptBox.Items.Add(new ComboBoxItem { Content = ResultsKeptLabel(kept), Tag = kept });
        }

        ResultsKeptBox.SelectedItem = ResultsKeptBox.Items
            .OfType<ComboBoxItem>()
            .First(item => item.Tag is int kept && kept == settings.ResultSetsKeptPerRun);
        CountThresholdBox.Items.Clear();
        var thresholds = AppSettings.CountThresholdChoices.Append(settings.CountRowsIfEstimateLessThan);
        foreach (var threshold in thresholds.Distinct().Order())
        {
            CountThresholdBox.Items.Add(new ComboBoxItem { Content = ThresholdLabel(threshold), Tag = threshold });
        }

        CountThresholdBox.SelectedItem = CountThresholdBox.Items
            .OfType<ComboBoxItem>()
            .First(item => item.Tag is long threshold && threshold == settings.CountRowsIfEstimateLessThan);
        FillFamilies(FontFamilyBox, SqlEditor.InstalledFontFamilies(monospacedOnly: true), settings.EditorFontFamily, "FontFamilyDefault");
        FillFamilies(GridFontBox, SqlEditor.InstalledFontFamilies(monospacedOnly: false), settings.GridFontFamily, "GridFontDefault");
        GridFontSizeBox.Value = settings.GridFontSize;
        NullDisplayBox.Text = settings.NullDisplay;
        FillChoices(HistoryRetentionBox, AppSettings.HistoryRetentionChoices, settings.HistoryRetentionDays, RetentionLabel);
        FillChoices(HistoryMaxBox, AppSettings.HistoryMaxEntriesChoices, settings.HistoryMaxEntries, MaxEntriesLabel);
        _loading = false;
    }

    // The app's own choice first, then each installed family; a saved family no longer installed still shows.
    private static void FillFamilies(ComboBox box, IReadOnlyList<string> installed, string? saved, string defaultKey)
    {
        box.Items.Clear();
        box.Items.Add(new ComboBoxItem { Content = Strings.Get(defaultKey), Tag = string.Empty });
        var families = saved is null || installed.Contains(saved, StringComparer.OrdinalIgnoreCase)
            ? installed
            : [saved, .. installed];
        foreach (var family in families)
        {
            box.Items.Add(new ComboBoxItem
            {
                Content = family,
                Tag = family,
                FontFamily = new Microsoft.UI.Xaml.Media.FontFamily(family),
            });
        }

        box.SelectedItem = box.Items
            .OfType<ComboBoxItem>()
            .FirstOrDefault(item => string.Equals(item.Tag as string, saved ?? string.Empty, StringComparison.OrdinalIgnoreCase))
            ?? box.Items[0];
    }

    private static void FillChoices(ComboBox box, IReadOnlyList<int> choices, int saved, Func<int, string> label)
    {
        box.Items.Clear();
        // A value the file holds that the list does not offer shows too, so the box never reads empty.
        foreach (var choice in choices.Append(saved).Distinct().OrderBy(choice => choice == 0 ? int.MaxValue : choice))
        {
            box.Items.Add(new ComboBoxItem { Content = label(choice), Tag = choice });
        }

        box.SelectedItem = box.Items.OfType<ComboBoxItem>().First(item => item.Tag is int value && value == saved);
    }

    private static string RetentionLabel(int days) => days switch
    {
        0 => Strings.Get("HistoryRetentionForever"),
        365 => Strings.Get("HistoryRetentionYear"),
        _ => Strings.Format("HistoryRetentionDays", days),
    };

    private static string MaxEntriesLabel(int entries) => entries == 0
        ? Strings.Get("HistoryMaxUnlimited")
        : Strings.Format("HistoryMaxOption", entries);

    private static string ResultsKeptLabel(int kept) => kept == 0
        ? Strings.Get("ResultsKeptNoLimit")
        : Strings.Format("ResultsKeptOption", kept);

    private static string ThresholdLabel(long threshold) => threshold == AppSettings.AlwaysCount
        ? Strings.Get("CountThresholdAlways")
        : Strings.Format("CountThresholdOption", threshold);

    private void OnThemeChanged(object sender, SelectionChangedEventArgs e)
    {
        if (_loading || ThemeBox.SelectedItem is not ComboBoxItem { Tag: string tag })
        {
            return;
        }

        var theme = Enum.Parse<AppTheme>(tag);
        _workbench.UpdateSettings(settings => settings with { Theme = theme });
    }

    private void OnReopenToggled(object sender, RoutedEventArgs e)
    {
        if (!_loading)
        {
            var reopen = ReopenSwitch.IsOn;
            _workbench.UpdateSettings(settings => settings with { ReopenSession = reopen });
        }
    }

    private void OnFontSizeChanged(NumberBox sender, NumberBoxValueChangedEventArgs args)
    {
        if (!_loading && !double.IsNaN(args.NewValue))
        {
            _workbench.UpdateSettings(settings => settings with { EditorFontSize = args.NewValue });
        }
    }

    private void OnFontFamilyChanged(object sender, SelectionChangedEventArgs e)
    {
        if (!_loading && FontFamilyBox.SelectedItem is ComboBoxItem { Tag: string family })
        {
            _workbench.UpdateSettings(settings => settings with { EditorFontFamily = family.Length == 0 ? null : family });
        }
    }

    private void OnGridFontChanged(object sender, SelectionChangedEventArgs e)
    {
        if (!_loading && GridFontBox.SelectedItem is ComboBoxItem { Tag: string family })
        {
            _workbench.UpdateSettings(settings => settings with { GridFontFamily = family.Length == 0 ? null : family });
        }
    }

    private void OnGridFontSizeChanged(NumberBox sender, NumberBoxValueChangedEventArgs args)
    {
        if (!_loading && !double.IsNaN(args.NewValue))
        {
            _workbench.UpdateSettings(settings => settings with { GridFontSize = args.NewValue });
        }
    }

    // An empty box shows NULL in the grid without writing NULL into the box while it is being typed in.
    private void OnNullDisplayChanged(object sender, TextChangedEventArgs e)
    {
        if (!_loading)
        {
            var text = NullDisplayBox.Text;
            _workbench.UpdateSettings(settings => settings with { NullDisplay = text });
        }
    }

    private void OnHistoryRetentionChanged(object sender, SelectionChangedEventArgs e)
    {
        if (!_loading && HistoryRetentionBox.SelectedItem is ComboBoxItem { Tag: int days })
        {
            _workbench.UpdateSettings(settings => settings with { HistoryRetentionDays = days });
        }
    }

    private void OnHistoryMaxChanged(object sender, SelectionChangedEventArgs e)
    {
        if (!_loading && HistoryMaxBox.SelectedItem is ComboBoxItem { Tag: int entries })
        {
            _workbench.UpdateSettings(settings => settings with { HistoryMaxEntries = entries });
        }
    }

    // Every connection's runs go, pinned ones included, so it asks first and Cancel is the default.
    private async void OnClearHistory(object sender, RoutedEventArgs e)
    {
        var dialog = new ContentDialog
        {
            XamlRoot = XamlRoot,
            RequestedTheme = ActualTheme,
            Title = Strings.Get("ClearHistoryTitle"),
            Content = Strings.Get("ClearHistoryMessage"),
            PrimaryButtonText = Strings.Get("ClearHistoryConfirm"),
            CloseButtonText = Strings.Get("Cancel"),
            DefaultButton = ContentDialogButton.Close,
        };
        if (await WindowDialogs.ShowAsync(dialog, this).ConfigureAwait(true) != ContentDialogResult.Primary)
        {
            return;
        }

        ClearHistoryButton.IsEnabled = false;
        try
        {
            await _workbench.ClearHistoryAsync().ConfigureAwait(true);
            ClearHistoryCard.Description = Strings.Get("ClearHistoryDone");
        }
        catch (TableProException exception)
        {
            ClearHistoryCard.Description = Strings.Error(exception.Error);
        }
        finally
        {
            ClearHistoryButton.IsEnabled = true;
        }
    }

    private void OnRowLimitChanged(NumberBox sender, NumberBoxValueChangedEventArgs args)
    {
        if (!_loading && !double.IsNaN(args.NewValue))
        {
            _workbench.UpdateSettings(settings => settings with { RowLimit = (int)args.NewValue });
        }
    }

    private void OnPageSizeChanged(object sender, SelectionChangedEventArgs e)
    {
        if (!_loading && PageSizeBox.SelectedItem is ComboBoxItem { Tag: int size })
        {
            _workbench.UpdateSettings(settings => settings with { PageSize = size });
        }
    }

    private void OnResultsKeptChanged(object sender, SelectionChangedEventArgs e)
    {
        if (!_loading && ResultsKeptBox.SelectedItem is ComboBoxItem { Tag: int kept })
        {
            _workbench.UpdateSettings(settings => settings with { ResultSetsKeptPerRun = kept });
        }
    }

    private void OnCountThresholdChanged(object sender, SelectionChangedEventArgs e)
    {
        if (!_loading && CountThresholdBox.SelectedItem is ComboBoxItem { Tag: long threshold })
        {
            _workbench.UpdateSettings(settings => settings with { CountRowsIfEstimateLessThan = threshold });
        }
    }

    private void OnTimeoutChanged(NumberBox sender, NumberBoxValueChangedEventArgs args)
    {
        if (!_loading && !double.IsNaN(args.NewValue))
        {
            _workbench.UpdateSettings(settings => settings with { QueryTimeoutSeconds = (int)args.NewValue });
        }
    }

    private void OnAccountChanged(object? sender, EventArgs e) => ShowAccount();

    // One card names the account and holds its one action; the notice above it says what needs doing.
    private void ShowAccount()
    {
        var panel = _workbench.AccountPanel;
        var signedIn = panel.Stage == AccountStage.SignedIn;
        AccountCard.Header = signedIn && panel.Title is { } title ? title : Strings.Get("AccountTitle");
        AccountCard.Description = panel.Stage switch
        {
            AccountStage.Unavailable when _workbench.AccountFailure is { } failure => Strings.Error(failure),
            AccountStage.SigningIn => Strings.Get("AccountSigningIn"),
            AccountStage.SignedIn => Strings.Format(
                "AccountSignedInDescription",
                panel.Email ?? string.Empty,
                Strings.Get(panel.IsPro ? "AccountPlanPro" : "AccountPlanFree")),
            AccountStage.Offline => Strings.Get("AccountOffline"),
            _ => Strings.Get("AccountSignedOut"),
        };
        AccountButton.Content = Strings.Get(panel.Stage switch
        {
            AccountStage.SigningIn => "Cancel",
            AccountStage.SignedIn => "AccountSignOut",
            _ => "AccountSignIn",
        });
        AccountButton.Visibility = panel.Stage == AccountStage.Unavailable ? Visibility.Collapsed : Visibility.Visible;
        AccountButton.IsEnabled = !_accountBusy;
        var busy = _accountBusy || panel.Stage == AccountStage.SigningIn;
        AccountProgress.IsActive = busy;
        AccountProgress.Visibility = busy ? Visibility.Visible : Visibility.Collapsed;
        AccountRefreshButton.IsEnabled = !_accountBusy;
        AccountDetails.Visibility = signedIn ? Visibility.Visible : Visibility.Collapsed;
        DevicesExpander.Visibility = signedIn ? Visibility.Visible : Visibility.Collapsed;
        ShowAccountNotice(panel);
    }

    // An error a press here met comes first, then the account's own problem.
    private void ShowAccountNotice(AccountPanel panel)
    {
        if (AccountNotice(panel) is not { } notice)
        {
            AccountBar.IsOpen = false;
            AccountBar.Visibility = Visibility.Collapsed;
            return;
        }

        var (title, message, severity, action) = notice;
        var changed = AccountBar.Message != message || !AccountBar.IsOpen;
        AccountBar.Title = title;
        AccountBar.Message = message;
        AccountBar.Severity = severity;
        AccountBar.ActionButton = action;
        AccountBar.Visibility = Visibility.Visible;
        if (changed)
        {
            // Narrator reads an InfoBar when it opens, not when its text changes.
            AccountBar.IsOpen = false;
            AccountBar.IsOpen = true;
        }
    }

    private (string Title, string Message, InfoBarSeverity Severity, Button? Action)? AccountNotice(AccountPanel panel)
    {
        if (_accountError is { } error)
        {
            return (Strings.Get("AccountErrorTitle"), Strings.Error(error), InfoBarSeverity.Error, null);
        }

        switch (panel.Notice)
        {
            case { Kind: AccountNoticeKind.Expired }:
                return (
                    Strings.Get("AccountExpiredTitle"),
                    Strings.Get("AccountExpiredMessage"),
                    InfoBarSeverity.Warning,
                    NoticeButton("AccountRefresh", OnAccountRefresh));
            case { Kind: AccountNoticeKind.RefreshFailed, Code: var code }:
                var failed = code ?? string.Empty;
                return (
                    Strings.Get("AccountRefreshFailedTitle"),
                    Strings.Error(new CoreError(failed, [failed], failed, null, null)),
                    InfoBarSeverity.Warning,
                    NoticeButton("AccountTryAgain", OnAccountRefresh));
            case { Kind: AccountNoticeKind.DeviceLimitReached }:
                return (
                    Strings.Get("DeviceLimitTitle"),
                    Strings.Get("AccountDeviceLimitMessage"),
                    InfoBarSeverity.Error,
                    NoticeButton("AccountRemoveDevice", OnRemoveDevice));
            case { Kind: AccountNoticeKind.NotRemembered }:
                return (
                    Strings.Get("AccountNotRememberedTitle"),
                    Strings.Get("AccountNotRememberedMessage"),
                    InfoBarSeverity.Informational,
                    null);
            default:
                return null;
        }
    }

    private static Button NoticeButton(string text, RoutedEventHandler click)
    {
        var button = new Button { Content = Strings.Get(text) };
        AutomationProperties.SetAutomationId(button, "AccountBarAction");
        button.Click += click;
        return button;
    }

    private async void OnAccountButton(object sender, RoutedEventArgs e)
    {
        switch (_workbench.AccountPanel.Stage)
        {
            case AccountStage.SigningIn:
                _workbench.CancelSignIn();
                break;
            case AccountStage.SignedIn:
                await RunAccountAsync(account => account.SignOutAsync());
                break;
            default:
                _accountError = null;
                try
                {
                    await _workbench.SignInAsync();
                }
                catch (TableProException exception)
                {
                    _accountError = exception.Error;
                }

                ShowAccount();
                break;
        }
    }

    private async void OnAccountRefresh(object sender, RoutedEventArgs e) =>
        await RunAccountAsync(account => account.RefreshAsync());

    private async void OnRemoveDevice(object sender, RoutedEventArgs e)
    {
        if (_workbench.AccountPanel is { LimitDevices.Count: > 0 } panel)
        {
            await DeviceLimitDialog.ShowAsync(this, _workbench, panel.LimitDevices);
        }
    }

    // One account call at a time from this page; the status it leaves shows when it ends, the error if it failed.
    private async Task RunAccountAsync(Func<TableProAccount, Task> call)
    {
        if (_accountBusy || await _workbench.GetAccountAsync() is not { } account)
        {
            return;
        }

        _accountBusy = true;
        _accountError = null;
        ShowAccount();
        try
        {
            await call(account);
        }
        catch (TableProException exception)
        {
            _accountError = exception.Error;
        }
        finally
        {
            _accountBusy = false;
            _workbench.ShowAccount(account.Status);
            ShowAccount();
        }
    }

    private async void OnManageAccount(object sender, RoutedEventArgs e) =>
        await Launcher.LaunchUriAsync(_workbench.Portal);

    private async void OnManageSharedLinks(object sender, RoutedEventArgs e) =>
        await Launcher.LaunchUriAsync(AccountSetup.SharedLinksPage(_workbench.Portal));

    // Read each time the list opens, since a device may have been removed on another one.
    private async void OnDevicesExpanded(object? sender, EventArgs e)
    {
        var generation = ++_devicesGeneration;
        DevicesExpander.Items.Clear();
        DevicesProgress.IsActive = true;
        DevicesProgress.Visibility = Visibility.Visible;
        try
        {
            if (await _workbench.GetAccountAsync() is not { } account)
            {
                return;
            }

            var devices = await account.GetDevicesAsync();
            if (generation != _devicesGeneration)
            {
                return;
            }

            foreach (var device in AccountDevices.Ordered(devices))
            {
                DevicesExpander.Items.Add(DeviceCard(device));
            }
        }
        catch (TableProException exception) when (generation == _devicesGeneration)
        {
            DevicesExpander.Items.Add(new SettingsCard { Header = Strings.Error(exception.Error) });
        }
        finally
        {
            if (generation == _devicesGeneration)
            {
                DevicesProgress.IsActive = false;
                DevicesProgress.Visibility = Visibility.Collapsed;
            }
        }
    }

    private SettingsCard DeviceCard(AccountDevice device)
    {
        var card = new SettingsCard { Header = device.Name, Description = DeviceLimitDialog.DeviceText(device) };
        if (AccountDevices.CanRemove(device, DateTimeOffset.Now))
        {
            var remove = new Button { Content = Strings.Get("DeviceRemove") };
            AutomationProperties.SetName(remove, Strings.Format("DeviceRemoveName", device.Name));
            remove.Click += async (_, _) =>
            {
                remove.IsEnabled = false;
                await RunAccountAsync(async current =>
                {
                    await current.RemoveDeviceAsync(device.Id);
                    DevicesExpander.Items.Remove(card);
                });
                remove.IsEnabled = true;
            };
            card.Content = remove;
        }

        return card;
    }

    private async void OnDocumentation(object sender, RoutedEventArgs e) =>
        await Launcher.LaunchUriAsync(DocumentationUri);

    private async void OnReportIssue(object sender, RoutedEventArgs e) =>
        await Launcher.LaunchUriAsync(IssuesUri);

    // LaunchFolderPathAsync needs Windows 10 1903; this form runs on 1809.
    private async void OnOpenDataFolder(object sender, RoutedEventArgs e)
    {
        try
        {
            // A folder removed while the app runs is made again, as the app's next write would make it.
            Directory.CreateDirectory(_workbench.Folder);
            await Launcher.LaunchFolderAsync(await Windows.Storage.StorageFolder.GetFolderFromPathAsync(_workbench.Folder));
        }
        catch (Exception exception) when (exception is IOException or UnauthorizedAccessException)
        {
            // The card names the folder, so it can still be opened by hand.
        }
    }
}
