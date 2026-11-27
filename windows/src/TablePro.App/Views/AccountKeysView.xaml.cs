using CommunityToolkit.WinUI.Controls;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using TablePro.App.Model;
using TablePro.App.Services;
using TablePro.Interop;

namespace TablePro.App.Views;

// Settings > Sync > End-to-end encryption (docs/decisions/0030-end-to-end-encryption.md): this computer's keys, the
// devices holding the account's keys, the requests waiting for approval and the reset, as AccountKeysPage and
// ResetKeys read them. A page swapped into the window, as the keyboard shortcuts page is.
public sealed partial class AccountKeysView : UserControl
{
    // How often an approved computer reads the requests waiting for it while the page is on screen.
    private static readonly TimeSpan RequestsInterval = TimeSpan.FromSeconds(5);

    private readonly Workbench _workbench;
    private readonly AccountKeysPage _page;
    private readonly ResetKeys _resets;
    private readonly Microsoft.UI.Dispatching.DispatcherQueueTimer _requests;
    private string? _session;
    private bool _busy;
    private (string Title, string Message)? _failure;

    internal AccountKeysView(Workbench workbench)
    {
        _workbench = workbench;
        InitializeComponent();
        _page = new AccountKeysPage(workbench.Sync.GetKeyFlowsAsync, workbench.StepUp);
        _resets = new ResetKeys(workbench.Sync.GetKeyFlowsAsync, workbench.StepUp, () => DateTimeOffset.Now);
        _page.Changed += (_, _) => Render();
        _resets.Changed += (_, _) => Render();
        _requests = DispatcherQueue.CreateTimer();
        _requests.Interval = RequestsInterval;
        _requests.Tick += async (_, _) =>
        {
            if (!_busy)
            {
                await _page.ReadRequestsAsync().ConfigureAwait(true);
            }
        };
        _session = workbench.SignInSession;
        Loaded += (_, _) =>
        {
            _workbench.SyncKeysChanged -= OnKeysChanged;
            _workbench.SyncKeysChanged += OnKeysChanged;
            _workbench.AccountChanged -= OnAccountChanged;
            _workbench.AccountChanged += OnAccountChanged;
            _requests.Start();
        };
        Unloaded += (_, _) =>
        {
            _workbench.SyncKeysChanged -= OnKeysChanged;
            _workbench.AccountChanged -= OnAccountChanged;
            _requests.Stop();
        };
        Render();
    }

    // Read again each time the page comes back.
    public void Refresh()
    {
        Scroller.ChangeView(null, 0, null, disableAnimation: true);
        _ = ReloadAsync();
    }

    private async Task ReloadAsync()
    {
        await _page.ReloadAsync().ConfigureAwait(true);
        await _resets.LoadAsync().ConfigureAwait(true);
    }

    private void OnKeysChanged(object? sender, EventArgs e) => _ = ReloadAsync();

    // Another account's keys, devices and requests never show under this one.
    private void OnAccountChanged(object? sender, EventArgs e)
    {
        if (_workbench.SignInSession == _session)
        {
            return;
        }

        _session = _workbench.SignInSession;
        _page.ForgetAccount();
        _resets.ForgetAccount();
        _ = ReloadAsync();
    }

    private void Render()
    {
        StateHost.Children.Clear();
        ShowBar();
        switch (_page.State)
        {
            case null when _page.StateFailure is { } failure:
                StateHost.Children.Add(Card(
                    "KeysStateCard",
                    Strings.Get("KeysReadFailedTitle"),
                    Strings.Error(failure),
                    ActionButton("KeysTryAgain", "AccountTryAgain", () => ReloadAsync())));
                break;
            case null or KeyState.Unknown:
                StateHost.Children.Add(Card("KeysStateCard", Strings.Get("KeysChecking"), null, Ring()));
                break;
            case KeyState.NoDeviceStore:
                StateHost.Children.Add(Card(
                    "KeysStateCard",
                    Strings.Get("KeysNoDeviceStoreTitle"),
                    Strings.Get("KeysNoDeviceStoreMessage"),
                    null));
                break;
            case KeyState.NoKeys:
                StateHost.Children.Add(Card(
                    "KeysStateCard",
                    Strings.Get("KeysSetUpCardTitle"),
                    Strings.Get("KeysSetUpCardMessage"),
                    ActionButton("KeysSetUpButton", "KeysSetUpButton", SetUpAsync)));
                break;
            case KeyState.NeedsApproval approval:
                StateHost.Children.Add(Card(
                    "KeysStateCard",
                    Strings.Get("KeysNeedsApprovalTitle"),
                    Strings.Get("KeysNeedsApprovalMessage"),
                    Actions(
                        ActionButton("KeysAskButton", "KeysAskForApproval", () => AskForApprovalAsync(approval.Request)),
                        ActionButton("KeysRecoverButton", "KeysUseRecoveryKeyButton", RecoverAsync))));
                break;
            case KeyState.Locked locked:
                var ways = new List<Button>();
                if (AccountKeysPage.CanAskForApproval(locked.Cause))
                {
                    ways.Add(ActionButton("KeysAskButton", "KeysAskForApproval", () => AskForApprovalAsync(null)));
                }

                if (AccountKeysPage.CanRecover(locked.Cause))
                {
                    ways.Add(ActionButton("KeysRecoverButton", "KeysUseRecoveryKeyButton", RecoverAsync));
                }

                StateHost.Children.Add(Card(
                    "KeysStateCard",
                    SyncText.LockTitle(locked.Cause),
                    SyncText.LockMessage(locked.Cause),
                    ways.Count > 0 ? Actions([.. ways]) : null));
                break;
            case KeyState.Approved:
                ShowApproved();
                break;
        }

        ShowResets();
    }

    // What the last action met, until the next one starts.
    private void ShowBar()
    {
        if (_failure is not { } failure)
        {
            KeysBar.IsOpen = false;
            KeysBar.Visibility = Visibility.Collapsed;
            return;
        }

        KeysBar.Title = failure.Title;
        KeysBar.Message = failure.Message;
        KeysBar.Severity = InfoBarSeverity.Error;
        KeysBar.Visibility = Visibility.Visible;
        KeysBar.IsOpen = true;
    }

    private void ShowApproved()
    {
        StateHost.Children.Add(Card(
            "KeysRecoveryKeyCard",
            Strings.Get("KeysRecoveryKeyTitle"),
            Strings.Get("KeysRecoveryKeyMessage"),
            ActionButton("KeysReplaceButton", "KeysReplaceButton", ReplaceAsync)));
        if (_page.Requests.Count > 0)
        {
            var requests = new SettingsExpander
            {
                Header = Strings.Get("KeysRequestsHeader"),
                Description = Strings.Get("KeysRequestsDescription"),
                IsExpanded = true,
            };
            AutomationProperties.SetAutomationId(requests, "KeysRequests");
            foreach (var request in _page.Requests)
            {
                var name = KeysText.DeviceName(request.DeviceName);
                var approve = ActionButton("KeysApproveRequest", "KeysApproveButton", () => ApproveAsync(request));
                AutomationProperties.SetName(approve, Strings.Format("KeysApproveName", name));
                requests.Items.Add(new SettingsCard
                {
                    Header = name,
                    Description = Strings.Format(
                        "KeysRequestDetail",
                        KeysText.Platform(request.Platform) ?? string.Empty,
                        request.RequestedAt.LocalDateTime),
                    Content = approve,
                });
            }

            StateHost.Children.Add(requests);
        }

        var devices = new SettingsExpander
        {
            Header = Strings.Get("KeysDevicesHeader"),
            Description = _page.DevicesFailure is { } failure
                ? Strings.Error(failure)
                : Strings.Get("KeysDevicesDescription"),
            IsExpanded = true,
        };
        AutomationProperties.SetAutomationId(devices, "KeysDevices");
        foreach (var device in _page.Devices)
        {
            var name = KeysText.DeviceName(device.Name);
            var card = new SettingsCard { Header = name, Description = KeysText.DeviceDetail(device) };
            if (!device.IsThisDevice)
            {
                var remove = ActionButton("KeysRemoveDevice", "DeviceRemove", () => RemoveAsync(device));
                remove.IsEnabled = _page.Removing is null && !_busy;
                AutomationProperties.SetName(remove, Strings.Format("DeviceRemoveName", name));
                card.Content = _page.Removing == device.KeyDeviceId ? Ring() : remove;
            }

            devices.Items.Add(card);
        }

        StateHost.Children.Add(devices);
    }

    private void ShowResets()
    {
        ResetHost.Children.Clear();
        var shows = _page.ShowsResets;
        ResetHeader.Visibility = shows ? Visibility.Visible : Visibility.Collapsed;
        if (!shows)
        {
            return;
        }

        if (_resets.Failure is { } failure)
        {
            ResetHost.Children.Add(Bar(Strings.Error(failure), InfoBarSeverity.Error, null, "KeysResetFailure"));
        }

        foreach (var notice in _resets.Notices)
        {
            var bar = Bar(
                KeysText.ResetNoticeText(notice),
                notice.Ended == ResetState.Active ? InfoBarSeverity.Success
                    : notice.WaitsForStepUp is not null ? InfoBarSeverity.Warning : InfoBarSeverity.Informational,
                notice.WaitsForStepUp is { } reset
                    ? ActionButton("KeysResetAskAgain", "KeysResetAskAgain", () => _resets.ProposeAgainAsync(reset))
                    : null,
                "KeysResetNotice");
            bar.IsClosable = true;
            bar.CloseButtonClick += async (_, _) => await _resets.DismissAsync(notice).ConfigureAwait(true);
            ResetHost.Children.Add(bar);
        }

        if (_resets.Pending is { } pending)
        {
            var actions = new List<Button>
            {
                ActionButton("KeysResetCancel", "KeysResetCancelButton", () => CancelResetAsync(pending)),
            };
            if (_resets.CanActivate(pending))
            {
                actions.Add(ActionButton("KeysResetFinish", "KeysResetFinishButton", () => ActivateResetAsync(pending)));
            }

            ResetHost.Children.Add(Card(
                "KeysPendingReset",
                Strings.Get("KeysResetPendingTitle"),
                KeysText.PendingResetText(pending),
                Actions([.. actions])));
        }
        else if (_resets.OfferedKind is { } kind)
        {
            ResetHost.Children.Add(Card(
                "KeysResetCard",
                Strings.Get("KeysResetCardTitle"),
                Strings.Get("KeysResetCard_" + kind),
                ActionButton("KeysResetButton", "KeysResetButton", () => ResetAsync(kind))));
        }
    }

    private async Task SetUpAsync()
    {
        if (await KeyDialogs.RecoveryKeyAsync(this, _workbench, RecoveryKeyPurpose.SetUp).ConfigureAwait(true)
            == KeyDialogResult.AskForApproval)
        {
            await AskForApprovalAsync(null).ConfigureAwait(true);
        }
    }

    private Task ReplaceAsync() => KeyDialogs.RecoveryKeyAsync(this, _workbench, RecoveryKeyPurpose.Replace);

    // A new request, or the one this computer already has open; one that ended asks again with a new one.
    private async Task AskForApprovalAsync(string? open)
    {
        var request = open;
        while (await KeyDialogs.ApprovalAsync(this, _workbench, null, request).ConfigureAwait(true)
            == KeyDialogResult.AskForApproval)
        {
            request = null;
        }
    }

    private Task ApproveAsync(ApprovalRequest request) => KeyDialogs.ApprovalAsync(this, _workbench, request, null);

    private Task RecoverAsync() => KeyDialogs.RecoverAsync(this, _workbench);

    // The row goes first behind a fresh step-up, then the recovery key and the review.
    private async Task RemoveAsync(KeyDevice device)
    {
        var name = KeysText.DeviceName(device.Name);
        if (!await KeyDialogs.ConfirmAsync(
                this,
                Strings.Format("KeysRemoveTitle", name),
                Strings.Get("KeysRemoveMessage"),
                Strings.Get("DeviceRemove"),
                "KeysRemoveDialog").ConfigureAwait(true))
        {
            return;
        }

        if (await _page.RemoveRowAsync(device).ConfigureAwait(true) is { } failure)
        {
            // The person closed the sign-in page: nothing to say.
            if (failure.Code is "account.sign_in_canceled")
            {
                return;
            }

            CrashLog.Note("keys remove row", failure.Code);
            _failure = (Strings.Format("KeysRemoveFailedTitle", name), Strings.Error(failure));
            return;
        }

        await KeyDialogs.RemovalAsync(this, _workbench, device).ConfigureAwait(true);
    }

    private Task ResetAsync(ResetKind kind) => KeyDialogs.ResetAsync(this, _workbench, kind);

    private async Task CancelResetAsync(PendingReset reset)
    {
        if (_resets.CancelsWithoutRecoveryKey)
        {
            if (await KeyDialogs.ConfirmAsync(
                    this,
                    Strings.Get("KeysResetCancelTitle"),
                    Strings.Get("KeysResetCancelMessage"),
                    Strings.Get("KeysResetCancelButton"),
                    "KeysResetCancelDialog").ConfigureAwait(true))
            {
                await _resets.CancelAsync(reset, null).ConfigureAwait(true);
            }

            return;
        }

        if (await KeyDialogs.AskRecoveryKeyAsync(
                this,
                Strings.Get("KeysResetCancelTitle"),
                Strings.Get("KeysResetCancelWithKeyMessage"),
                Strings.Get("KeysResetCancelButton")).ConfigureAwait(true) is { } key)
        {
            await _resets.CancelAsync(reset, key).ConfigureAwait(true);
        }
    }

    private async Task ActivateResetAsync(PendingReset reset)
    {
        if (await KeyDialogs.ConfirmAsync(
                this,
                Strings.Get("KeysResetFinishTitle"),
                Strings.Get("KeysResetFinishMessage"),
                Strings.Get("KeysResetFinishButton"),
                "KeysResetFinishDialog").ConfigureAwait(true))
        {
            await _resets.ActivateAsync(reset).ConfigureAwait(true);
        }
    }

    // One flow at a time from this page; the page reads again once it ends.
    private Button ActionButton(string automationId, string text, Func<Task> run)
    {
        var button = new Button { Content = Strings.Get(text), IsEnabled = !_busy };
        AutomationProperties.SetAutomationId(button, automationId);
        button.Click += async (_, _) =>
        {
            if (_busy)
            {
                return;
            }

            _busy = true;
            _failure = null;
            Render();
            try
            {
                await run().ConfigureAwait(true);
            }
            finally
            {
                _busy = false;
                await ReloadAsync().ConfigureAwait(true);
            }
        };
        return button;
    }

    private static StackPanel Actions(params Button[] buttons)
    {
        var row = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8 };
        foreach (var button in buttons)
        {
            row.Children.Add(button);
        }

        return row;
    }

    private static SettingsCard Card(string automationId, string header, string? description, object? content)
    {
        var card = new SettingsCard { Header = header, Description = description, Content = content };
        AutomationProperties.SetAutomationId(card, automationId);
        return card;
    }

    private static InfoBar Bar(string message, InfoBarSeverity severity, Button? action, string automationId)
    {
        var bar = new InfoBar
        {
            Message = message,
            Severity = severity,
            ActionButton = action,
            IsClosable = false,
            IsOpen = true,
        };
        AutomationProperties.SetAutomationId(bar, automationId);
        return bar;
    }

    private static ProgressRing Ring() => new() { Width = 20, Height = 20, IsActive = true };
}
