using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using TablePro.App.Model;
using TablePro.App.Services;
using TablePro.Interop;
using Windows.System;

namespace TablePro.App.Views;

// Settings' Sync section (docs/decisions/0029-tablepro-sync.md): Off or TablePro Sync, its status, the server's
// switches and the categories, laid out as SyncPane decides.
public sealed partial class SettingsView
{
    private bool _syncChoosing;
    private bool _syncingNow;
    private bool _identityChoosing;
    private CoreError? _syncProblem;
    private CoreError? _identityProblem;

    private void LoadSync()
    {
        var sync = _workbench.Settings.Sync;
        SyncConnectionsSwitch.IsOn = sync.Connections;
        SyncPasswordsSwitch.IsOn = sync.Passwords;
        SyncGroupsSwitch.IsOn = sync.GroupsAndTags;
        SyncSavedQueriesSwitch.IsOn = sync.SavedQueries;
        SyncTableFavoritesSwitch.IsOn = sync.TableFavorites;
        SyncDatabaseFavoritesSwitch.IsOn = sync.DatabaseFavorites;
        SyncProviderBox.SelectedIndex = sync.Provider == SyncProvider.TableProSync ? 1 : 0;
    }

    private void OnSyncChanged(object? sender, EventArgs e) => ShowSync();

    private void ShowSync()
    {
        var sync = _workbench.Settings.Sync;
        var host = _workbench.Sync;
        var pane = SyncPane.For(new SyncPaneInputs(
            sync.Provider,
            _workbench.SyncAccess,
            host.Status,
            host.Scopes,
            host.Keys,
            host.OpenFailure,
            host.AccountChoice is not null));
        _loading = true;
        LoadSync();
        _loading = false;
        SyncProviderTableProSyncItem.IsEnabled = pane.OffersTableProSync;
        SyncProviderBox.IsEnabled = !_syncChoosing && !host.IsMoving;
        SyncProviderCard.Description = SyncText.ProviderSummary(sync.Provider);
        ShowSyncNotice(pane.Notice);
        ShowSyncGate(pane.ShowsGate);
        ShowSyncPolicies(pane.ServerPolicies);
        ShowSyncStatus(pane);
        SyncCategoriesExpander.Visibility = pane.ShowsCategories ? Visibility.Visible : Visibility.Collapsed;
        SyncPasswordsCard.IsEnabled = sync.Connections && !pane.PasswordsOffOnServer;
        SyncPasswordsCard.Description = Strings.Get(pane.PasswordsOffOnServer
            ? "SyncPasswordsOffOnServer"
            : "SyncPasswordsEncrypted");
    }

    private void ShowSyncStatus(SyncPane pane)
    {
        if (pane.Status is not { } kind)
        {
            SyncStatusCard.Visibility = Visibility.Collapsed;
            return;
        }

        var busy = _syncingNow || kind is SyncStatusKind.Syncing or SyncStatusKind.Starting;
        SyncStatusCard.Visibility = Visibility.Visible;
        SyncStatusCard.Header = SyncText.Status(kind);
        SyncStatusCard.Description = _syncProblem is { } problem ? Strings.Error(problem) : SyncText.Detail(pane);
        SyncStatusIcon.Glyph = SyncText.Glyph(kind);
        SyncProgress.IsActive = busy;
        SyncProgress.Visibility = busy ? Visibility.Visible : Visibility.Collapsed;
        SyncNowButton.Visibility = pane.OffersSyncNow ? Visibility.Visible : Visibility.Collapsed;
        SyncNowButton.IsEnabled = !busy;
    }

    // A server's switch is stated where the choice of provider is, as the macOS pane states it.
    private void ShowSyncPolicies(IReadOnlyList<SyncServerPolicy> policies)
    {
        SyncPoliciesHost.Children.Clear();
        foreach (var policy in policies)
        {
            var bar = new InfoBar
            {
                Message = SyncText.Policy(policy),
                Severity = policy == SyncServerPolicy.PersonalSyncOff
                    ? InfoBarSeverity.Warning
                    : InfoBarSeverity.Informational,
                IsClosable = false,
                IsOpen = true,
            };
            AutomationProperties.SetAutomationId(bar, "SyncPolicy_" + policy);
            SyncPoliciesHost.Children.Add(bar);
        }

        SyncPoliciesHost.Visibility = policies.Count > 0 ? Visibility.Visible : Visibility.Collapsed;
    }

    private void ShowSyncNotice(SyncNotice? notice)
    {
        if (notice != SyncNotice.NewIdentity)
        {
            _identityProblem = null;
        }

        switch (notice)
        {
            case SyncNotice.NewIdentity:
                ShowNewIdentity();
                break;
            case SyncNotice.UploadsPaused:
                ShowSyncBar(
                    Strings.Get("SyncUploadsPausedTitle"),
                    Strings.Get("SyncUploadsPausedMessage"),
                    InfoBarSeverity.Warning,
                    null);
                break;
            default:
                SyncBar.IsOpen = false;
                SyncBar.Visibility = Visibility.Collapsed;
                break;
        }
    }

    // Nothing goes up to another account or server until the person picks (core ADR 0054, Another account or server).
    private void ShowNewIdentity()
    {
        var plan = _workbench.Sync.AccountChoice;
        var message = _identityProblem is { } problem
            ? Strings.Error(problem)
            : plan is { Unsent: > 0 }
                ? Strings.Sentences(
                    Strings.Get("SyncNewIdentityMessage"),
                    Strings.Plural("SyncNewIdentityUnsent", plan.Unsent, plan.Unsent))
                : Strings.Get("SyncNewIdentityMessage");
        var choices = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8, Margin = new Thickness(0, 0, 0, 12) };
        choices.Children.Add(IdentityButton("SyncStartEmpty", NewIdentityChoice.StartEmpty, plan));
        choices.Children.Add(IdentityButton("SyncMoveMyData", NewIdentityChoice.MoveMyData, plan));
        ShowSyncBar(Strings.Get("SyncNewIdentityTitle"), message, InfoBarSeverity.Warning, null);
        SyncBar.Content = choices;
    }

    private Button IdentityButton(string name, NewIdentityChoice choice, NewIdentityPlan? plan)
    {
        var button = new Button
        {
            Content = Strings.Get(name),
            IsEnabled = plan is not null && !_identityChoosing,
        };
        AutomationProperties.SetAutomationId(button, name);
        if (plan is not null)
        {
            button.Click += async (_, _) => await ChooseIdentityAsync(choice, plan).ConfigureAwait(true);
        }

        return button;
    }

    // An answer for an account that changed meanwhile is refused, and the host reads the choice again.
    private async Task ChooseIdentityAsync(NewIdentityChoice choice, NewIdentityPlan plan)
    {
        _identityChoosing = true;
        _identityProblem = null;
        ShowSync();
        try
        {
            await _workbench.Sync.ChooseForNewIdentityAsync(choice, plan).ConfigureAwait(true);
        }
        catch (TableProException exception)
        {
            CrashLog.Note("sync new identity", exception.Code);
            _identityProblem = exception.Error;
        }
        finally
        {
            _identityChoosing = false;
        }

        ShowSync();
    }

    // The plan's gate stands in place of the status, with the action it offers (docs/decisions/0023).
    private void ShowSyncGate(bool shows)
    {
        if (!shows || _workbench.Gate(PlanFeatures.ServiceSync) is not { } notice)
        {
            SyncGateBar.IsOpen = false;
            SyncGateBar.Visibility = Visibility.Collapsed;
            return;
        }

        var action = new Button { Content = LicenseText.Action(notice.Action) };
        AutomationProperties.SetAutomationId(action, "SyncGateAction");
        action.Click += async (_, _) => await PerformGateActionAsync(notice.Action).ConfigureAwait(true);
        SyncGateBar.Title = LicenseText.Title(notice, PlanFeatures.ServiceSync);
        SyncGateBar.Message = LicenseText.Message(notice, PlanFeatures.ServiceSync);
        SyncGateBar.Severity = InfoBarSeverity.Warning;
        SyncGateBar.ActionButton = action;
        SyncGateBar.Visibility = Visibility.Visible;
        SyncGateBar.IsOpen = true;
    }

    private async Task PerformGateActionAsync(LicenseAction action)
    {
        switch (action)
        {
            case LicenseAction.SignIn:
                await SignInAsync().ConfigureAwait(true);
                break;
            case LicenseAction.TryAgain:
                await RefreshAccountAsync().ConfigureAwait(true);
                break;
            case LicenseAction.Purchase or LicenseAction.Upgrade:
                var referrer = PlanFeatures.GateReferrer(PlanFeatures.ServiceSync);
                await Launcher.LaunchUriAsync(AccountSetup.Pricing(referrer));
                break;
            default:
                ShowAccountSection();
                break;
        }
    }

    private void ShowSyncBar(string title, string message, InfoBarSeverity severity, Button? action)
    {
        SyncBar.Title = title;
        SyncBar.Message = message;
        SyncBar.Severity = severity;
        SyncBar.ActionButton = action;
        SyncBar.Content = null;
        SyncBar.Visibility = Visibility.Visible;
        SyncBar.IsOpen = true;
    }

    // The stored provider changes only once the core side of the choice returned, so the box goes back to it after.
    private async void OnSyncProviderChanged(object sender, SelectionChangedEventArgs e)
    {
        if (_loading || SyncProviderBox.SelectedItem is not ComboBoxItem { Tag: string tag })
        {
            return;
        }

        var chosen = Enum.Parse<SyncProvider>(tag);
        if (chosen == _workbench.Settings.Sync.Provider || _syncChoosing)
        {
            return;
        }

        _syncChoosing = true;
        ShowSync();
        try
        {
            if (chosen == SyncProvider.Off)
            {
                await _workbench.Sync.TurnOffAsync().ConfigureAwait(true);
            }
            else if (await _shell.RequirePlanAsync(PlanFeatures.ServiceSync).ConfigureAwait(true))
            {
                await SyncUploadDialog.ShowAsync(this, _workbench).ConfigureAwait(true);
            }
        }
        finally
        {
            _syncChoosing = false;
            ShowSync();
        }
    }

    private void OnSyncCategoryToggled(object sender, RoutedEventArgs e)
    {
        if (_loading)
        {
            return;
        }

        var connections = SyncConnectionsSwitch.IsOn;
        var passwords = SyncPasswordsSwitch.IsOn;
        var groups = SyncGroupsSwitch.IsOn;
        var savedQueries = SyncSavedQueriesSwitch.IsOn;
        var tableFavorites = SyncTableFavoritesSwitch.IsOn;
        var databaseFavorites = SyncDatabaseFavoritesSwitch.IsOn;
        _workbench.UpdateSettings(settings => settings with
        {
            Sync = (settings.Sync with
            {
                Passwords = passwords,
                GroupsAndTags = groups,
                SavedQueries = savedQueries,
                TableFavorites = tableFavorites,
                DatabaseFavorites = databaseFavorites,
            }).WithConnections(connections),
        });
        ShowSync();
    }

    private async void OnSyncNow(object sender, RoutedEventArgs e)
    {
        _syncingNow = true;
        _syncProblem = null;
        ShowSync();
        _syncProblem = await _workbench.Sync.SyncNowAsync().ConfigureAwait(true);
        _syncingNow = false;
        ShowSync();
    }
}
