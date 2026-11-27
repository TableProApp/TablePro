using TablePro.Interop;

namespace TablePro.App.Model.Tests;

public sealed class TeamKeysTests
{
    private const string Team = "team_01h455vb4pex5vsknk084sn02q";

    private static readonly KeysTeam Admin = new(Team, "Data", TeamRole.Admin);

    private static readonly KeysTeam Owner = new(Team, "Data", TeamRole.Owner);

    private readonly FakeTeamCalls _calls = new();

    private static MemberKeys Member(string account, MemberKeyStatus status, bool self = false) =>
        new(account, account, null, self, TeamRole.Member, status);

    private static TeamKeys Keys(
        long? version = 3,
        bool holder = true,
        TeamKeyState state = TeamKeyState.Ok,
        StopCause? cause = null,
        params MemberKeys[] members) =>
        new(Team, "Data", version, state, cause, false, holder, members, []);

    private TeamKeysModel Model(KeysTeam team) =>
        new(team, () => Task.FromResult<ITeamCalls>(_calls), new StepUpRetry(_ => Task.CompletedTask));

    [Fact]
    public void TheStatusSaysAnEndedOrStoppedKeyBeforeAnythingElse()
    {
        Assert.Equal(TeamKeyStatus.Ended, TeamKeysModel.StatusOf(Keys(state: TeamKeyState.Ended), Admin));
        Assert.Equal(
            TeamKeyStatus.RestartHeld,
            TeamKeysModel.StatusOf(Keys(state: TeamKeyState.Stopped, cause: StopCause.RestartHeld), Admin));
        Assert.Equal(TeamKeyStatus.StoppedCatchUp, TeamKeysModel.StatusOf(Keys(state: TeamKeyState.Stopped), Admin));
        Assert.Equal(TeamKeyStatus.NoKeys, TeamKeysModel.StatusOf(Keys(version: null), Owner));
        Assert.Equal(TeamKeyStatus.NoHolderLeft, TeamKeysModel.StatusOf(Keys(holder: false), Owner));
        Assert.Equal(
            TeamKeyStatus.AwaitingConfirmation,
            TeamKeysModel.StatusOf(Keys(holder: false, members: [Member("A", MemberKeyStatus.Holder)]), Admin));
        Assert.Equal(TeamKeyStatus.Holder, TeamKeysModel.StatusOf(Keys(), Admin));
    }

    [Fact]
    public async Task OnlyAHolderWhoManagesKeysConfirmsAndAKeyChangeIsComparedFirst()
    {
        _calls.Keys = Keys(members: [Member("A", MemberKeyStatus.AwaitingConfirmation), Member("B", MemberKeyStatus.Alert),
            Member("ME", MemberKeyStatus.Holder, self: true)]);
        var admin = Model(Admin);
        var member = Model(new KeysTeam(Team, "Data", TeamRole.Member));

        await admin.LoadAsync();
        await member.LoadAsync();

        Assert.Equal(TeamMemberAction.Confirm, admin.ActionFor(admin.Member("A")!));
        Assert.Equal(TeamMemberAction.CompareKeyChange, admin.ActionFor(admin.Member("B")!));
        Assert.Null(admin.ActionFor(admin.Member("ME")!));
        Assert.Null(member.ActionFor(member.Member("A")!));
        Assert.Equal(["A"], admin.RestartCandidates.Select(each => each.Account));
        Assert.Equal(["B"], admin.RestartWaitsForKeyChange.Select(each => each.Account));
    }

    [Fact]
    public async Task AcceptingAKeyChangePinsItAndAnAdminWrapsTheKeyToIt()
    {
        _calls.Keys = Keys(members: [Member("B", MemberKeyStatus.Alert)]);
        var admin = Model(Admin);
        await admin.LoadAsync();

        var accepted = await admin.AcceptKeyChangeAsync(admin.Member("B")!, "IK", compared: true);

        Assert.True(accepted);
        Assert.Equal(
            [$"team keys {Team}", "notices", "accept change B IK True", $"confirm {Team} B", $"team keys {Team}", "notices"],
            _calls.Calls);
    }

    [Fact]
    public async Task AFailedActionSaysWhyAndReadsTheKeysAgain()
    {
        _calls.Keys = Keys();
        _calls.Fails["rotate"] = SyncErrors.Of("sync.rejected");
        var owner = Model(Owner);

        var rotated = await owner.RotateAsync();

        Assert.False(rotated);
        Assert.Equal("sync.rejected", owner.Failure?.Code);
        Assert.NotNull(owner.Snapshot);
        Assert.Null(owner.Work);
    }

    [Fact]
    public void TheNoticesAreThisTeamsAndItsMembersOnly()
    {
        var keys = Keys(members: [Member("A", MemberKeyStatus.Alert)]);
        KeyNotice[] notices =
        [
            new("N-1", new KeyNoticeKind.KeysChanged("A")),
            new("N-2", new KeyNoticeKind.KeysChanged("STRANGER")),
            new("N-3", new KeyNoticeKind.RestartHeld(Team, "A")),
            new("N-4", new KeyNoticeKind.TeamKeyRestarted("team_other")),
            new("N-5", new KeyNoticeKind.DeviceRemoved("D")),
        ];

        var mine = TeamKeysModel.NoticesFor(notices, Team, keys);

        Assert.Equal(["N-1", "N-3"], mine.Select(notice => notice.Id));
        Assert.Equal(TeamKeyNoticeKind.RestartHeld, mine[1].Kind);
        Assert.True(Admin.ManagesKeys);
        Assert.False(new KeysTeam(Team, "Data", TeamRole.Editor).ManagesKeys);
        Assert.False(new KeysTeam(Team, "Data", null).ManagesKeys);
    }
}
