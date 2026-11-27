using CommunityToolkit.WinUI.Controls;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using TablePro.App.Model;
using TablePro.App.Services;
using TablePro.Interop;

namespace TablePro.App.Views;

// Settings > Sync > Team keys (docs/decisions/0031-team-library-and-team-keys.md): one card per team Team Library
// reads, its key's status and, where this account is an owner or admin, its members and stopped devices, as the macOS
// app's TeamKeysPage shows them. A page swapped into the window, as the end-to-end encryption page is.
public sealed partial class TeamKeysView : UserControl
{
    private readonly Workbench _workbench;
    private readonly Dictionary<string, TeamKeysModel> _models = new(StringComparer.Ordinal);
    private string? _session;
    private bool _busy;

    internal TeamKeysView(Workbench workbench)
    {
        _workbench = workbench;
        InitializeComponent();
        _session = workbench.SignInSession;
        Loaded += (_, _) =>
        {
            _workbench.TeamLibraryChanged -= OnTeamsChanged;
            _workbench.TeamLibraryChanged += OnTeamsChanged;
            _workbench.SyncKeysChanged -= OnKeysChanged;
            _workbench.SyncKeysChanged += OnKeysChanged;
        };
        Unloaded += (_, _) =>
        {
            _workbench.TeamLibraryChanged -= OnTeamsChanged;
            _workbench.SyncKeysChanged -= OnKeysChanged;
        };
        Render();
    }

    // Read again each time the page comes back; another account's teams never show while it reads.
    public void Refresh()
    {
        Scroller.ChangeView(null, 0, null, disableAnimation: true);
        ForgetIfSignInChanged();
        FollowTeams();
        foreach (var model in _models.Values)
        {
            _ = model.LoadAsync();
        }

        _workbench.RefreshTeamLibrary();
    }

    private void OnTeamsChanged(object? sender, EventArgs e)
    {
        ForgetIfSignInChanged();
        FollowTeams();
    }

    private void OnKeysChanged(object? sender, EventArgs e)
    {
        if (_busy)
        {
            return;
        }

        foreach (var model in _models.Values)
        {
            _ = model.LoadAsync();
        }
    }

    private void ForgetIfSignInChanged()
    {
        if (_workbench.SignInSession == _session)
        {
            return;
        }

        _session = _workbench.SignInSession;
        foreach (var model in _models.Values)
        {
            model.Changed -= OnModelChanged;
        }

        _models.Clear();
        Render();
    }

    // A model per team the library reads now; a team whose role changed starts over with the new one.
    private void FollowTeams()
    {
        IReadOnlyList<TeamView> teams = _workbench.TeamLibraryAvailable ? _workbench.TeamLibrary.Teams : [];
        var ids = teams.Select(team => team.TeamId).ToHashSet(StringComparer.Ordinal);
        foreach (var gone in _models.Keys.Where(id => !ids.Contains(id)).ToList())
        {
            _models[gone].Changed -= OnModelChanged;
            _models.Remove(gone);
        }

        foreach (var team in teams)
        {
            var keysTeam = KeysTeam.Of(team);
            if (_models.TryGetValue(team.TeamId, out var shown))
            {
                if (shown.Team == keysTeam)
                {
                    continue;
                }

                shown.Changed -= OnModelChanged;
            }

            var session = _session;
            var model = new TeamKeysModel(
                keysTeam,
                () => _workbench.SignInSession == session
                    ? _workbench.Sync.GetTeamCallsAsync()
                    : Task.FromException<ITeamCalls>(new TableProException(KeyErrors.Changed)),
                _workbench.StepUp);
            model.Changed += OnModelChanged;
            _models[team.TeamId] = model;
            _ = model.LoadAsync();
        }

        Render();
    }

    private void OnModelChanged(object? sender, EventArgs e) => Render();

    private void Render()
    {
        TeamsHost.Children.Clear();
        var library = _workbench.TeamLibrary;
        if (!_workbench.TeamLibraryAvailable)
        {
            TeamsHost.Children.Add(Card("TeamKeysEmpty", Strings.Get("TeamKeysUnavailable"), null, null));
            return;
        }

        if (_models.Count == 0)
        {
            TeamsHost.Children.Add(library.LoadFailure is { } failure
                ? Card(
                    "TeamKeysEmpty",
                    Strings.Get("TeamLibraryReadFailed"),
                    Strings.Error(failure),
                    ActionButton("TeamKeysTryAgain", "AccountTryAgain", () =>
                    {
                        _workbench.RefreshTeamLibrary();
                        return Task.CompletedTask;
                    }))
                : Card("TeamKeysEmpty", Strings.Get("TeamKeysNoTeams"), null, null));
            return;
        }

        foreach (var team in library.Teams)
        {
            if (_models.TryGetValue(team.TeamId, out var model))
            {
                AddTeam(model);
            }
        }
    }

    private void AddTeam(TeamKeysModel model)
    {
        var name = TeamText.Team(model.Team.Name);
        if (model.Failure is { } failure)
        {
            var bar = new InfoBar
            {
                Title = Strings.Format("TeamKeysFailedTitle", name),
                Message = Strings.Error(failure),
                Severity = InfoBarSeverity.Error,
                IsClosable = false,
                IsOpen = true,
            };
            AutomationProperties.SetAutomationId(bar, "TeamKeysFailure");
            TeamsHost.Children.Add(bar);
        }

        var card = new SettingsExpander
        {
            Header = name,
            Description = Describe(model),
            Content = model.Work is not null ? Ring() : Action(model),
            IsExpanded = true,
        };
        AutomationProperties.SetAutomationId(card, "TeamKeysCard");
        AutomationProperties.SetName(card, name);
        foreach (var notice in model.Notices)
        {
            card.Items.Add(NoticeCard(model, notice));
        }

        if (model.Snapshot is { } snapshot && model.Team.ManagesKeys)
        {
            foreach (var member in snapshot.Members)
            {
                card.Items.Add(MemberCard(model, member));
            }

            foreach (var device in snapshot.Stopped)
            {
                card.Items.Add(StoppedCard(model, device));
            }
        }

        TeamsHost.Children.Add(card);
    }

    private static string Describe(TeamKeysModel model)
    {
        if (model.Snapshot is not { } snapshot)
        {
            return model.LoadFailure is { } failure ? Strings.Error(failure) : Strings.Get("TeamKeysLoading");
        }

        var status = TeamKeysModel.StatusOf(snapshot, model.Team);
        return status switch
        {
            TeamKeyStatus.NoKeys when model.Team.IsOwner => Strings.Get("TeamKeyStatus_NoKeysCreate"),
            TeamKeyStatus.NoHolderLeft when model.Team.IsOwner => Strings.Get("TeamKeyStatus_NoHolderLeftRestart"),
            TeamKeyStatus.Holder => Strings.Format("TeamKeyStatus_Holder", snapshot.Version ?? 0),
            _ => TeamText.KeyStatus(status),
        };
    }

    private Button? Action(TeamKeysModel model)
    {
        if (model.Snapshot is not { } snapshot)
        {
            return model.LoadFailure is not null
                ? ActionButton("TeamKeysTryAgain", "AccountTryAgain", model.LoadAsync)
                : null;
        }

        return TeamKeysModel.StatusOf(snapshot, model.Team) switch
        {
            TeamKeyStatus.RestartHeld =>
                ActionButton("TeamKeysCompare", "TeamCompareWords", () => TeamDialogs.HeldRestartAsync(this, _workbench, model)),
            TeamKeyStatus.NoKeys when model.Team.IsOwner =>
                ActionButton("TeamKeysCreate", "TeamCreateKeys", model.CreateKeysAsync),
            TeamKeyStatus.NoHolderLeft when model.Team.IsOwner =>
                ActionButton("TeamKeysRestart", "TeamStartOver", () => TeamDialogs.RestartAsync(this, _workbench, model)),
            TeamKeyStatus.AwaitingConfirmation =>
                ActionButton("TeamKeysShowWords", "TeamShowMyWordsButton", () => TeamDialogs.OwnWordsAsync(this, _workbench)),
            TeamKeyStatus.RotationDue when model.Team.ManagesKeys =>
                ActionButton("TeamKeysRotate", "TeamRotate", () => RotateAsync(model, "TeamRotateTitle", "TeamRotateMessage")),
            _ => null,
        };
    }

    private SettingsCard NoticeCard(TeamKeysModel model, TeamKeyNotice notice)
    {
        var member = notice.Account is { } account ? model.Member(account) : null;
        var actions = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8 };
        if (notice.Kind == TeamKeyNoticeKind.KeysChanged && member is { Status: MemberKeyStatus.Alert })
        {
            actions.Children.Add(ActionButton(
                "TeamNoticeCompare",
                "TeamCompare",
                () => TeamDialogs.KeyChangeAsync(this, _workbench, model, member)));
        }
        else if (notice.Kind == TeamKeyNoticeKind.RestartHeld)
        {
            actions.Children.Add(ActionButton(
                "TeamNoticeCompare",
                "TeamCompare",
                () => TeamDialogs.HeldRestartAsync(this, _workbench, model)));
        }

        actions.Children.Add(ActionButton("TeamNoticeDismiss", "TeamDismiss", () => model.DismissAsync(notice)));
        return Card("TeamKeyNotice", TeamText.Notice(notice, member), null, actions);
    }

    private SettingsCard MemberCard(TeamKeysModel model, MemberKeys member)
    {
        var name = TeamText.MemberName(member);
        Button? action = model.ActionFor(member) switch
        {
            TeamMemberAction.Confirm => ActionButton(
                "TeamMemberConfirm",
                "TeamConfirmEllipsis",
                () => TeamDialogs.ConfirmMemberAsync(this, _workbench, model, member)),
            TeamMemberAction.CompareKeyChange => ActionButton(
                "TeamMemberCompare",
                "TeamCompare",
                () => TeamDialogs.KeyChangeAsync(this, _workbench, model, member)),
            _ => null,
        };
        if (action is not null)
        {
            AutomationProperties.SetName(action, Strings.Format(
                model.ActionFor(member) == TeamMemberAction.Confirm ? "TeamConfirmName" : "TeamCompareName",
                name));
        }

        return Card(
            "TeamMember",
            name,
            Strings.List([TeamText.Role(member.Role), TeamText.MemberStatus(member.Status)]),
            action);
    }

    // A device the team stopped on: an owner or admin who held its version confirms it again by rotating.
    private SettingsCard StoppedCard(TeamKeysModel model, StoppedDevice device)
    {
        var who = device.IsSelf
            ? Strings.Get("TeamStoppedOwnDevice")
            : Strings.Format("TeamStoppedDevice", device.Name ?? device.Email ?? Strings.Get("KeysUnnamedTeammate"));
        var action = device.CanReconfirm
            ? ActionButton("TeamStoppedConfirm", "TeamConfirmAgain", () =>
                RotateAsync(model, "TeamReconfirmTitle", "TeamReconfirmMessage"))
            : null;
        return Card(
            "TeamStoppedDevice",
            who,
            Strings.Format(device.CanReconfirm ? "TeamStoppedAt" : "TeamStoppedAtOthers", device.Version),
            action);
    }

    private async Task RotateAsync(TeamKeysModel model, string title, string message)
    {
        if (await KeyDialogs.ConfirmAsync(
                this,
                Strings.Get(title),
                Strings.Get(message),
                Strings.Get("TeamRotateButton"),
                "TeamRotateDialog").ConfigureAwait(true))
        {
            await model.RotateAsync().ConfigureAwait(true);
        }
    }

    private async void OnShowMyWords(object sender, RoutedEventArgs e) =>
        await TeamDialogs.OwnWordsAsync(this, _workbench).ConfigureAwait(true);

    // One flow at a time from this page; each team reads again once its action ends.
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
            Render();
            try
            {
                await run().ConfigureAwait(true);
            }
            finally
            {
                _busy = false;
                Render();
            }
        };
        return button;
    }

    private static SettingsCard Card(string automationId, string header, string? description, object? content)
    {
        var card = new SettingsCard { Header = header, Description = description, Content = content };
        AutomationProperties.SetAutomationId(card, automationId);
        return card;
    }

    private static ProgressRing Ring() => new() { Width = 20, Height = 20, IsActive = true };
}
