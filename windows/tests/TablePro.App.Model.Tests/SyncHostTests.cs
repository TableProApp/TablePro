using TablePro.Interop;

namespace TablePro.App.Model.Tests;

public sealed class SyncHostTests
{
    private readonly FakeSyncApp _app = new();

    [Fact]
    public async Task APcOnTableProSyncOpensAtStartAndOneThatIsOffWaitsForFirstUse()
    {
        _app.Sync = new SyncSettings { Provider = SyncProvider.TableProSync, ServiceAccount = "service-1" };
        using var syncing = new SyncHost(_app);
        var offApp = new FakeSyncApp();
        using var off = new SyncHost(offApp);

        syncing.Start();
        off.Start();
        await syncing.GetEngineAsync();

        var configuration = Assert.Single(_app.Configurations);
        Assert.Equal(SyncProvider.TableProSync, configuration.Provider);
        Assert.Equal("service-1", configuration.ServiceAccount);
        Assert.Equal(5_000, Assert.Single(_app.Opened).HistoryWindow);
        Assert.Empty(offApp.Configurations);
    }

    [Fact]
    public async Task TheKindsTheSwitchesLeaveOutReachTheOpenAndEachChange()
    {
        _app.Sync = new SyncSettings { SavedQueries = false };
        using var host = new SyncHost(_app);
        host.Start();
        var engine = (FakeSyncEngine)(await host.GetEngineAsync())!;

        _app.Sync = _app.Sync.WithConnections(false);
        await host.ApplyCategoriesAsync();

        Assert.Equal(["saved_query", "saved_query_folder"], _app.Configurations[0].Categories.OffKinds);
        Assert.Equal(
            "categories connection,connection_project,ssh_profile,credential_profile,saved_query,saved_query_folder"
            + " passwords False",
            Assert.Single(engine.Calls));
    }

    [Fact]
    public async Task ASignInChangeClosesTheServiceAndOpensItAgain()
    {
        using var host = new SyncHost(_app);
        host.Start();
        var first = (FakeSyncEngine)(await host.GetEngineAsync())!;

        _app.SignIn = "account-2";
        host.SignInChanged();
        var second = await host.GetEngineAsync();

        Assert.True(first.IsDisposed);
        Assert.NotSame(first, second);
        Assert.Equal(2, _app.Opened.Count);
    }

    [Fact]
    public async Task ALeaseKeepsTheServiceOfASignInThatEndedUntilItIsReleased()
    {
        using var host = new SyncHost(_app);
        host.Start();
        var first = (FakeSyncEngine)(await host.GetEngineAsync())!;
        var lease = await host.LeaseAsync();

        _app.SignIn = "account-2";
        host.SignInChanged();
        var kept = !first.IsDisposed;
        Assert.Same(first.TeamCalls, lease!.Team);
        lease.Dispose();
        lease.Dispose();

        Assert.True(kept);
        Assert.True(first.IsDisposed);
        Assert.NotSame(first, await host.GetEngineAsync());
    }

    [Fact]
    public void ASignInChangeOpensNothingThatWasNeitherOpenNorWanted()
    {
        using var host = new SyncHost(_app);
        host.Start();

        host.SignInChanged();

        Assert.Empty(_app.Opened);
        Assert.Null(host.Status);
        Assert.Null(host.Keys);
    }

    [Fact]
    public async Task AnUploadWaitsForTheAccountsKeysAndLeavesThePcOff()
    {
        _app.Prepare = engine => engine.KeysState = new KeyState.NeedsApproval(null);
        using var host = new SyncHost(_app);
        host.Start();

        var outcome = await host.UploadAsync("account-1");

        var needs = Assert.IsType<UploadOutcome.NeedsKeys>(outcome);
        Assert.IsType<KeyState.NeedsApproval>(needs.State);
        Assert.Equal(SyncProvider.Off, _app.Sync.Provider);
        Assert.Empty(Assert.Single(_app.Opened).Calls);
        Assert.Equal(UploadKeysStep.ApproveThisPc, UploadKeys.StepFor(needs.State));
    }

    [Fact]
    public async Task AnUploadConfirmedUnderAnotherSignInGoesNowhere()
    {
        using var host = new SyncHost(_app);
        host.Start();

        var outcome = await host.UploadAsync("account-0");

        Assert.Equal(new UploadOutcome.Refused(SyncRefusal.SignInChanged), outcome);
        Assert.Empty(_app.Opened);
    }

    [Fact]
    public async Task AnApprovedUploadKeepsTableProSyncAndOpensAgainWithIt()
    {
        using var host = new SyncHost(_app);
        host.Start();

        var outcome = await host.UploadAsync("account-1");

        Assert.Same(UploadOutcome.Uploaded.Instance, outcome);
        Assert.Equal(SyncProvider.TableProSync, _app.Sync.Provider);
        Assert.Equal(
            [SyncProvider.Off, SyncProvider.TableProSync],
            _app.Configurations.Select(configuration => configuration.Provider));
        var (first, second) = (_app.Opened[0], _app.Opened[1]);
        Assert.Equal(["choose TableProSync"], first.Calls);
        Assert.True(first.IsDisposed);
        Assert.Equal(["pass Person"], second.Calls);
        Assert.False(host.IsMoving);
    }

    [Fact]
    public async Task AServerThatKeepsNoPersonalDataRefusesTheUpload()
    {
        _app.Prepare = engine => engine.Scopes = [new SyncScopeStatus("personal", true, false, null, null)];
        using var host = new SyncHost(_app);
        host.Start();

        var outcome = await host.UploadAsync("account-1");

        Assert.Equal(new UploadOutcome.Refused(SyncRefusal.ServerRefusesPersonalSync), outcome);
        Assert.Equal(SyncProvider.Off, _app.Sync.Provider);
    }

    [Fact]
    public async Task AnUploadWaitsForAnotherAccountsChoice()
    {
        _app.Prepare = engine => engine.Choice = new NewIdentityPlan(0, "account-0");
        using var host = new SyncHost(_app);
        host.Start();

        var outcome = await host.UploadAsync("account-1");

        Assert.Equal(new UploadOutcome.Refused(SyncRefusal.AccountChoicePending), outcome);
        Assert.Empty(Assert.Single(_app.Opened).Calls);
    }

    [Fact]
    public async Task AFailedUploadSaysWhyAndLeavesThePcOff()
    {
        _app.Prepare = engine => engine.ChooseFails = SyncErrors.Of("sync.network");
        using var host = new SyncHost(_app);
        host.Start();

        var outcome = await host.UploadAsync("account-1");

        Assert.Equal("sync.network", Assert.IsType<UploadOutcome.Failed>(outcome).Error.Code);
        Assert.Equal(SyncProvider.Off, _app.Sync.Provider);
        Assert.Single(_app.Opened);
    }

    [Fact]
    public async Task AServiceThatDidNotOpenSaysWhyAndTheNextUseTriesAgain()
    {
        _app.OpenFails = SyncErrors.Of("sync.device_store.unavailable");
        using var host = new SyncHost(_app);
        host.Start();

        var outcome = await host.UploadAsync("account-1");
        _app.OpenFails = null;
        var opened = await host.GetEngineAsync();

        Assert.Equal("sync.device_store.unavailable", Assert.IsType<UploadOutcome.Failed>(outcome).Error.Code);
        Assert.NotNull(opened);
        Assert.Null(host.OpenFailure);
        Assert.Equal(["open: sync.device_store.unavailable"], _app.Notes);
    }

    [Fact]
    public async Task TurningOffIsKeptAtOnceAndTheServiceOpensAgainOff()
    {
        _app.Sync = new SyncSettings { Provider = SyncProvider.TableProSync };
        using var host = new SyncHost(_app);
        host.Start();
        var first = (FakeSyncEngine)(await host.GetEngineAsync())!;

        await host.TurnOffAsync();

        Assert.Equal(SyncProvider.Off, _app.Sync.Provider);
        Assert.Equal(["choose Off"], first.Calls);
        Assert.True(first.IsDisposed);
        Assert.Equal(SyncProvider.Off, _app.Configurations[^1].Provider);
    }

    [Fact]
    public async Task AnotherAccountsChoiceIsReadAndTheSignInTheStateFileFollowsIsKept()
    {
        _app.Prepare = engine =>
        {
            engine.ServiceAccount = "service-1";
            engine.Choice = new NewIdentityPlan(4, "account-2");
        };
        using var host = new SyncHost(_app);
        host.Start();

        await host.GetEngineAsync();
        var plan = host.AccountChoice;
        await host.ChooseForNewIdentityAsync(NewIdentityChoice.StartEmpty, plan!);

        Assert.Equal(new NewIdentityPlan(4, "account-2"), plan);
        Assert.Null(host.AccountChoice);
        Assert.Equal("account-2", _app.Sync.ServiceAccount);
        Assert.Equal(["new identity StartEmpty account-2", "pass Person"], _app.Opened[0].Calls);
    }

    [Fact]
    public async Task AnAnswerForAnAccountThatChangedIsRefusedAndTheChoiceReadAgain()
    {
        _app.Prepare = engine => engine.Choice = new NewIdentityPlan(4, "account-3");
        using var host = new SyncHost(_app);
        host.Start();
        await host.GetEngineAsync();

        var refused = await Assert.ThrowsAsync<TableProException>(
            () => host.ChooseForNewIdentityAsync(NewIdentityChoice.MoveMyData, new NewIdentityPlan(4, "account-2")));

        Assert.Equal("sync.changed", refused.Code);
        Assert.Equal("account-3", host.AccountChoice?.Account);
    }

    [Fact]
    public async Task TurningOffWhileAnOpenRunsDropsItAndOpensAgainOff()
    {
        // Its continuation runs inside SetResult, so what the open does on landing has happened when it returns.
        var opening = new TaskCompletionSource<ISyncEngine>();
        var app = new SlowOpenApp(opening.Task) { Sync = new SyncSettings { Provider = SyncProvider.TableProSync } };
        using var host = new SyncHost(app);
        host.Start();

        var off = host.TurnOffAsync();
        var first = new FakeSyncEngine();
        opening.SetResult(first);
        await off;
        await host.GetEngineAsync();

        Assert.True(first.IsDisposed);
        Assert.Equal(
            [SyncProvider.TableProSync, SyncProvider.Off],
            app.Configurations.Select(configuration => configuration.Provider));
    }

    [Fact]
    public async Task ASwitchChangedWhileTheOpenRanReachesTheService()
    {
        // Its continuation runs inside SetResult, so what the open does on landing has happened when it returns.
        var opening = new TaskCompletionSource<ISyncEngine>();
        var app = new SlowOpenApp(opening.Task) { Sync = new SyncSettings { Provider = SyncProvider.TableProSync } };
        using var host = new SyncHost(app);
        host.Start();

        app.Sync = app.Sync with { SavedQueries = false };
        await host.ApplyCategoriesAsync();
        var engine = new FakeSyncEngine();
        opening.SetResult(engine);
        await host.GetEngineAsync();
        await host.ApplyCategoriesAsync();

        Assert.Contains("categories saved_query,saved_query_folder passwords True", engine.Calls);
    }

    [Fact]
    public async Task AnUploadARestartCutShortIsKeptOnceItArrived()
    {
        _app.Prepare = engine => engine.OpenUpload = _app.Opened.Count == 0 ? true : null;
        using var host = new SyncHost(_app);
        host.Start();

        await host.GetEngineAsync();
        var reopened = await host.GetEngineAsync();

        Assert.Equal(SyncProvider.TableProSync, _app.Sync.Provider);
        Assert.Equal(2, _app.Opened.Count);
        Assert.Same(_app.Opened[1], reopened);
    }

    [Fact]
    public async Task AFailedPassIsSaidAndLogged()
    {
        _app.Prepare = engine => engine.PassFails = SyncErrors.Of("sync.rate_limited");
        using var host = new SyncHost(_app);
        host.Start();

        var failure = await host.SyncNowAsync();

        Assert.Equal("sync.rate_limited", failure?.Code);
        Assert.Equal(["sync now: sync.rate_limited"], _app.Notes);
    }

    [Fact]
    public async Task AKeysChangeIsReadAgain()
    {
        using var host = new SyncHost(_app);
        host.Start();
        var engine = (FakeSyncEngine)(await host.GetEngineAsync())!;
        var changed = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        host.Changed += (_, _) =>
        {
            if (host.Keys is KeyState.Locked)
            {
                changed.TrySetResult();
            }
        };

        engine.KeysState = new KeyState.Locked(SyncLockCause.DeviceRemoved);
        engine.Raise(SyncChanges.Keys);
        await changed.Task.WaitAsync(TimeSpan.FromSeconds(10), TestContext.Current.CancellationToken);

        Assert.Equal(new KeyState.Locked(SyncLockCause.DeviceRemoved), host.Keys);
    }

    // The first open waits on the test; any later one opens at once.
    private sealed class SlowOpenApp(Task<ISyncEngine> first) : ISyncHostApp
    {
        private readonly List<SyncConfiguration> _configurations = [];

        public SyncSettings Sync { get; set; } = new();

        public int? HistoryWindow => null;

        public string? SignIn => "session-1";

        public IReadOnlyList<SyncConfiguration> Configurations => _configurations;

        public void UpdateSync(Func<SyncSettings, SyncSettings> change) => Sync = change(Sync);

        public Task<ISyncEngine> OpenAsync(SyncConfiguration configuration)
        {
            _configurations.Add(configuration);
            return _configurations.Count == 1 ? first : Task.FromResult<ISyncEngine>(new FakeSyncEngine());
        }

        public void Note(string what, CoreError failure)
        {
        }
    }
}
