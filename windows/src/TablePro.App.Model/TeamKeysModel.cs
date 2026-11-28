using TablePro.Interop;

namespace TablePro.App.Model;

// A team as Team Library reads it, with this account's role there, null until the server named it; owners and admins
// manage its keys.
public sealed record KeysTeam(string Id, string? Name, TeamRole? Role)
{
    public bool ManagesKeys => Role is TeamRole.Owner or TeamRole.Admin;

    public bool IsOwner => Role == TeamRole.Owner;

    public static KeysTeam Of(TeamView team)
    {
        ArgumentNullException.ThrowIfNull(team);
        return new KeysTeam(team.TeamId, team.Name, team.Role);
    }
}

// What the team key's status row says and offers, in order of precedence: an ended or stopped key says so first.
public enum TeamKeyStatus
{
    Ended,
    StoppedCatchUp,
    RestoreWait,
    RestartHeld,
    NoKeys,
    NoHolderLeft,
    AwaitingConfirmation,
    RotationDue,
    Holder,
}

public enum TeamMemberAction
{
    Confirm,
    CompareKeyChange,
}

public enum TeamKeyNoticeKind
{
    KeysChanged,
    RecoveryKeyReplaced,
    Restarted,
    RestartHeld,
    SupersededWrap,
    Conflict,
}

// Account names the member a notice is about, or the restart's signer.
public sealed record TeamKeyNotice(string Id, TeamKeyNoticeKind Kind, string? Account);

public enum TeamKeysWork
{
    Creating,
    Confirming,
    Accepting,
    Rotating,
    Restarting,
    AcceptingRestart,
    Dismissing,
}

// One team's keys (core ADR 0056, Pins and Teams), ported from the macOS app's TeamKeysModel and TeamKeysPresentation.
// Every action reads again after it ends, since a refusal such as create_only means the state moved on. Everything runs
// on the UI thread.
public sealed class TeamKeysModel
{
    private readonly Func<Task<ITeamCalls>> _calls;
    private readonly StepUpRetry _stepUp;
    // A load still out when a newer one starts lands nowhere.
    private int _generation;

    public TeamKeysModel(KeysTeam team, Func<Task<ITeamCalls>> calls, StepUpRetry stepUp)
    {
        ArgumentNullException.ThrowIfNull(team);
        ArgumentNullException.ThrowIfNull(calls);
        ArgumentNullException.ThrowIfNull(stepUp);
        Team = team;
        _calls = calls;
        _stepUp = stepUp;
    }

    public event EventHandler? Changed;

    public KeysTeam Team { get; }

    public TeamKeys? Snapshot { get; private set; }

    public IReadOnlyList<TeamKeyNotice> Notices { get; private set; } = [];

    public CoreError? LoadFailure { get; private set; }

    public TeamKeysWork? Work { get; private set; }

    // What the last action met.
    public CoreError? Failure { get; private set; }

    public TeamKeyStatus? Status => Snapshot is { } snapshot ? StatusOf(snapshot, Team) : null;

    public bool CanWrapCurrentVersion => Snapshot is { } snapshot && CanWrap(snapshot, Team);

    public static TeamKeyStatus StatusOf(TeamKeys snapshot, KeysTeam team)
    {
        ArgumentNullException.ThrowIfNull(snapshot);
        ArgumentNullException.ThrowIfNull(team);
        switch (snapshot.State)
        {
            case TeamKeyState.Ended:
                return TeamKeyStatus.Ended;
            case TeamKeyState.Stopped:
                return snapshot.StoppedCause switch
                {
                    StopCause.RestartHeld => TeamKeyStatus.RestartHeld,
                    StopCause.RestoreWait => TeamKeyStatus.RestoreWait,
                    _ => TeamKeyStatus.StoppedCatchUp,
                };
        }

        if (snapshot.Version is null)
        {
            return TeamKeyStatus.NoKeys;
        }

        // Only an owner restarts, and only while no one on the roster holds the key.
        if (!snapshot.Holder && !snapshot.Members.Any(member => member.Status == MemberKeyStatus.Holder))
        {
            return TeamKeyStatus.NoHolderLeft;
        }

        if (!snapshot.Holder)
        {
            return TeamKeyStatus.AwaitingConfirmation;
        }

        return snapshot.RotationDue ? TeamKeyStatus.RotationDue : TeamKeyStatus.Holder;
    }

    // Wrapping the current version is a write under the team key, so a stopped computer and a non-holder confirm no one.
    public static bool CanWrap(TeamKeys snapshot, KeysTeam team)
    {
        ArgumentNullException.ThrowIfNull(snapshot);
        ArgumentNullException.ThrowIfNull(team);
        return team.ManagesKeys && snapshot.State == TeamKeyState.Ok && snapshot.Holder && snapshot.Version is not null;
    }

    public TeamMemberAction? ActionFor(MemberKeys member)
    {
        ArgumentNullException.ThrowIfNull(member);
        if (member.IsSelf || Snapshot is not { } snapshot)
        {
            return null;
        }

        return member.Status switch
        {
            MemberKeyStatus.Alert => TeamMemberAction.CompareKeyChange,
            MemberKeyStatus.AwaitingConfirmation when CanWrap(snapshot, Team) => TeamMemberAction.Confirm,
            _ => null,
        };
    }

    // An owner restarts to those who could take a wrap; a member under a key-change alert takes none until accepted.
    public IReadOnlyList<MemberKeys> RestartCandidates => Snapshot is { } snapshot
        ? [.. snapshot.Members.Where(member =>
            !member.IsSelf && member.Status is MemberKeyStatus.AwaitingConfirmation or MemberKeyStatus.Holder)]
        : [];

    public IReadOnlyList<MemberKeys> RestartWaitsForKeyChange => Snapshot is { } snapshot
        ? [.. snapshot.Members.Where(member => !member.IsSelf && member.Status == MemberKeyStatus.Alert)]
        : [];

    public MemberKeys? Member(string account) => Snapshot?.Members.FirstOrDefault(member => member.Account == account);

    public async Task LoadAsync()
    {
        var generation = ++_generation;
        try
        {
            var calls = await _calls().ConfigureAwait(true);
            var snapshot = await calls.GetTeamKeysAsync(Team.Id).ConfigureAwait(true);
            if (generation != _generation)
            {
                return;
            }

            Snapshot = snapshot;
            LoadFailure = null;
            try
            {
                var notices = await calls.GetKeyNoticesAsync().ConfigureAwait(true);
                if (generation == _generation)
                {
                    Notices = NoticesFor(notices, Team.Id, snapshot);
                }
            }
            catch (Exception exception) when (KeyErrors.Of(exception) is not null)
            {
                // The notices stay as they were until the next read.
            }
        }
        catch (Exception exception) when (KeyErrors.Of(exception) is { } error)
        {
            if (generation == _generation)
            {
                LoadFailure = error;
            }
        }

        if (generation == _generation)
        {
            Changed?.Invoke(this, EventArgs.Empty);
        }
    }

    // The notices about this team and its members; a stopped or ended team key shows in the status instead.
    public static IReadOnlyList<TeamKeyNotice> NoticesFor(IReadOnlyList<KeyNotice> notices, string team, TeamKeys? snapshot)
    {
        ArgumentNullException.ThrowIfNull(notices);
        bool Known(string account) => snapshot?.Members.Any(member => member.Account == account) == true;
        return
        [
            .. notices.Select(notice => notice.Kind switch
            {
                KeyNoticeKind.KeysChanged changed when Known(changed.Account) =>
                    new TeamKeyNotice(notice.Id, TeamKeyNoticeKind.KeysChanged, changed.Account),
                KeyNoticeKind.RecoveryKeyReplaced replaced when Known(replaced.Account) =>
                    new TeamKeyNotice(notice.Id, TeamKeyNoticeKind.RecoveryKeyReplaced, replaced.Account),
                KeyNoticeKind.TeamKeyRestarted restarted when restarted.Team == team =>
                    new TeamKeyNotice(notice.Id, TeamKeyNoticeKind.Restarted, null),
                KeyNoticeKind.RestartHeld held when held.Team == team =>
                    new TeamKeyNotice(notice.Id, TeamKeyNoticeKind.RestartHeld, held.Signer),
                KeyNoticeKind.SupersededWrap superseded when superseded.Team == team =>
                    new TeamKeyNotice(notice.Id, TeamKeyNoticeKind.SupersededWrap, null),
                KeyNoticeKind.Conflict conflict when conflict.Scope == team =>
                    new TeamKeyNotice(notice.Id, TeamKeyNoticeKind.Conflict, null),
                _ => null,
            }).OfType<TeamKeyNotice>(),
        ];
    }

    public Task<bool> CreateKeysAsync() =>
        PerformAsync(TeamKeysWork.Creating, calls => calls.CreateTeamKeysAsync(Team.Id));

    public Task<bool> ConfirmAsync(MemberKeys member)
    {
        ArgumentNullException.ThrowIfNull(member);
        return PerformAsync(TeamKeysWork.Confirming, calls => calls.ConfirmMemberAsync(Team.Id, member.Account));
    }

    // Accepting is this computer's pin; an owner or admin then wraps the current version to the new key.
    public Task<bool> AcceptKeyChangeAsync(MemberKeys member, string offeredIdentityKey, bool compared)
    {
        ArgumentNullException.ThrowIfNull(member);
        var reconfirms = CanWrapCurrentVersion;
        return PerformAsync(TeamKeysWork.Accepting, async calls =>
        {
            await calls.AcceptKeyChangeAsync(member.Account, offeredIdentityKey, compared).ConfigureAwait(true);
            if (reconfirms)
            {
                await calls.ConfirmMemberAsync(Team.Id, member.Account).ConfigureAwait(true);
            }
        });
    }

    public Task<bool> RotateAsync() =>
        PerformAsync(TeamKeysWork.Rotating, calls => calls.RotateTeamKeyAsync(Team.Id, []));

    public Task<bool> RestartAsync(IReadOnlyList<string> confirming) =>
        PerformAsync(TeamKeysWork.Restarting, calls => calls.RestartTeamKeyAsync(Team.Id, confirming));

    public Task<bool> AcceptRestartAsync(string signerIdentityKey) =>
        PerformAsync(TeamKeysWork.AcceptingRestart, calls => calls.AcceptTeamRestartAsync(Team.Id, signerIdentityKey));

    public Task<bool> DismissAsync(TeamKeyNotice notice)
    {
        ArgumentNullException.ThrowIfNull(notice);
        return PerformAsync(TeamKeysWork.Dismissing, calls => calls.DismissKeyNoticeAsync(notice.Id));
    }

    private async Task<bool> PerformAsync(TeamKeysWork work, Func<ITeamCalls, Task> call)
    {
        if (Work is not null)
        {
            return false;
        }

        Work = work;
        Failure = null;
        Changed?.Invoke(this, EventArgs.Empty);
        var done = false;
        try
        {
            var calls = await _calls().ConfigureAwait(true);
            await _stepUp.RunAsync(() => call(calls)).ConfigureAwait(true);
            done = true;
        }
        catch (Exception exception) when (KeyErrors.Of(exception) is { } error)
        {
            // A sign-in page the person closed says nothing.
            if (error.Code != KeyErrors.Cancelled.Code)
            {
                Failure = error;
            }
        }
        finally
        {
            Work = null;
        }

        await LoadAsync().ConfigureAwait(true);
        return done;
    }
}
