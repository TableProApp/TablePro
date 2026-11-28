using TablePro.Interop;

namespace TablePro.App.Model.Tests;

public sealed class TeamSignOutTests
{
    private const string Team = "team_01h455vb4pex5vsknk084sn02q";

    private static readonly TeamLibraryOwner Account = new("https://api.tablepro.app", "acct-1");

    private readonly FakeSyncApp _app = new();
    private readonly List<TeamSignOutQuestion> _asked = [];

    [Fact]
    public async Task ALapsedTeamLibraryWhoseServiceDidNotStartAsksAboutEditsItCannotList()
    {
        _app.Prepare = engine =>
        {
            engine.TeamCalls.Owner = null;
            engine.TeamCalls.Unsent.Add(Pending());
        };
        using var host = new SyncHost(_app);
        host.Start();
        using var flow = Flow(host, hadTeamLibrary: true, TeamSignOutAnswer.Cancel);

        var signsOut = await flow.BeforeSignOutAsync();

        Assert.False(signsOut);
        Assert.Null(Assert.Single(_asked).Names);
        Assert.DoesNotContain("sign out keys", _app.Opened[0].KeyFlows.Calls);
    }

    [Fact]
    public async Task EditsNobodyWasAskedAboutAreNotDeletedWhenTheKeyEraseStartsTheService()
    {
        _app.Prepare = engine =>
        {
            engine.TeamCalls.Owner = null;
            engine.TeamCalls.Unsent.Add(Pending());
            engine.KeyFlows.AfterSignOutKeys = () => engine.TeamCalls.Owner = Account;
        };
        using var host = new SyncHost(_app);
        host.Start();
        using var flow = Flow(host, hadTeamLibrary: false);

        var signsOut = await flow.BeforeSignOutAsync();
        var deleted = await flow.AfterSignOutAsync();

        Assert.True(signsOut);
        Assert.Empty(_asked);
        Assert.Null(deleted);
        Assert.DoesNotContain("delete data", _app.Opened[0].TeamCalls.Calls);
    }

    [Fact]
    public async Task UploadWhenTheEditsCannotBeListedStartsTheServiceAgain()
    {
        _app.Prepare = engine =>
        {
            engine.TeamCalls.Owner = null;
            engine.TeamCalls.OwnerAfterSyncNow = Account;
            engine.TeamCalls.UploadSends = false;
            engine.TeamCalls.Unsent.Add(Pending());
        };
        using var host = new SyncHost(_app);
        host.Start();
        using var flow = Flow(host, hadTeamLibrary: true, TeamSignOutAnswer.Upload, TeamSignOutAnswer.Discard);

        var signsOut = await flow.BeforeSignOutAsync();
        var deleted = await flow.AfterSignOutAsync();

        Assert.True(signsOut);
        Assert.Null(_asked[0].Names);
        Assert.Equal(["Top users"], _asked[1].Names!);
        Assert.Null(deleted);
        Assert.Equal(["sync now", "unsent", "delete data"], _app.Opened[0].TeamCalls.Calls);
    }

    [Fact]
    public async Task TheKeyEraseRunsOnTheLeasedServiceWhenSyncReopensWhileSignOutAsks()
    {
        _app.Prepare = engine => engine.TeamCalls.Unsent.Add(Pending());
        using var host = new SyncHost(_app);
        host.Start();
        var first = (FakeSyncEngine)(await host.GetEngineAsync())!;
        using var flow = new TeamSignOutFlow(
            host.LeaseAsync,
            host.GetKeyFlowsAsync,
            () => true,
            asksWhenUnlisted: true,
            async _ =>
            {
                // A resumed upload reopens Sync while the question is open.
                host.SignInChanged();
                await host.GetEngineAsync();
                return TeamSignOutAnswer.Discard;
            },
            _ => Task.FromResult(KeysSignOutAnswer.Cancel));

        var signsOut = await flow.BeforeSignOutAsync();
        var kept = !first.IsDisposed;
        flow.Dispose();

        Assert.True(signsOut);
        Assert.True(kept);
        Assert.Contains("sign out keys", first.KeyFlows.Calls);
        Assert.DoesNotContain("sign out keys", _app.Opened[1].KeyFlows.Calls);
        Assert.True(first.IsDisposed);
    }

    private static UnsentTeamEdit Pending() =>
        new(Team, new TeamItemRef(TeamItemKind.Query, "Q-1"), "Top users", false, UnsentTeamEditState.Pending, null);

    private TeamSignOutFlow Flow(SyncHost host, bool hadTeamLibrary, params TeamSignOutAnswer[] answers)
    {
        var queue = new Queue<TeamSignOutAnswer>(answers);
        return new TeamSignOutFlow(
            host.LeaseAsync,
            host.GetKeyFlowsAsync,
            () => true,
            hadTeamLibrary,
            question =>
            {
                _asked.Add(question);
                return Task.FromResult(queue.Dequeue());
            },
            _ => Task.FromResult(KeysSignOutAnswer.Cancel));
    }
}
