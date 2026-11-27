using TablePro.Interop;

namespace TablePro.App.Model.Tests;

public sealed class KeyFlowTests
{
    private readonly FakeKeyFlows _keys = new();

    private static readonly KeyDevice ThisComputer = new("D-THIS", "row-this", "Desk", "windows", null, true, false);

    private static readonly KeyDevice Laptop =
        new("D-LAPTOP", "row-laptop", "Laptop", "macos", DateTimeOffset.UnixEpoch, false, true);

    private static readonly KeyDevice Phone =
        new("D-PHONE", null, "Phone", "ios", DateTimeOffset.UnixEpoch.AddDays(1), false, false);

    private Task<IKeyFlows> Flows() => Task.FromResult<IKeyFlows>(_keys);

    [Fact]
    public async Task SetUpShowsTheKeyThenChecksTwoGroupsBeforeAnythingGoesUp()
    {
        var flow = new RecoveryKeyFlow(RecoveryKeyPurpose.SetUp, Flows);

        await flow.StartAsync();
        var groups = flow.Groups;
        var check = flow.Check;
        await flow.AdvanceAsync();
        flow.SetTyped(0, " cccc ");
        var before = flow.CanContinue;
        flow.SetTyped(1, "KKKK");
        await flow.AdvanceAsync();

        Assert.Equal(14, groups.Count);
        Assert.Equal([2, 9], check);
        Assert.False(before);
        Assert.Equal(RecoveryKeyStep.Done, flow.Step);
        Assert.Empty(flow.Groups);
        Assert.Equal(["begin genesis", "finish genesis DRAFT cccc,KKKK"], _keys.Calls);
    }

    [Fact]
    public async Task AGroupTypedWrongStaysOnTheCheckWithTheCoresWords()
    {
        _keys.Fails["finish genesis"] = SyncErrors.Of("sync.typed_back_wrong");
        var flow = new RecoveryKeyFlow(RecoveryKeyPurpose.SetUp, Flows);
        await flow.StartAsync();
        await flow.AdvanceAsync();
        flow.SetTyped(0, "XXXX");
        flow.SetTyped(1, "YYYY");

        await flow.AdvanceAsync();

        Assert.Equal(RecoveryKeyStep.TypeBack, flow.Step);
        Assert.Equal("sync.typed_back_wrong", flow.Failure?.Code);
        Assert.True(flow.HasKey);
    }

    [Fact]
    public async Task AnotherDevicesSetUpWinsAndThisOneAsksForApproval()
    {
        _keys.Genesis = GenesisOutcome.AnotherDeviceWon;
        var flow = new RecoveryKeyFlow(RecoveryKeyPurpose.SetUp, Flows);
        await flow.StartAsync();
        await flow.AdvanceAsync();
        flow.SetTyped(0, "CCCC");
        flow.SetTyped(1, "KKKK");

        await flow.AdvanceAsync();

        Assert.Equal(RecoveryKeyStep.AnotherDeviceWon, flow.Step);
    }

    [Fact]
    public async Task ReplacingKeepsOnlyComparedDevicesAndThisComputer()
    {
        _keys.Reviewed =
        [
            new ReviewedDevice(ThisComputer, true),
            new ReviewedDevice(Laptop, true),
            new ReviewedDevice(Phone, true),
        ];
        var flow = new RecoveryKeyFlow(RecoveryKeyPurpose.Replace, Flows) { CurrentKey = " OLD-KEY " };

        await flow.AdvanceAsync();
        var step = flow.Step;
        flow.SetKeep(_keys.Reviewed[2], true);
        await flow.AdvanceAsync();
        await flow.AdvanceAsync();
        flow.SetTyped(0, "CCCC");
        flow.SetTyped(1, "KKKK");
        await flow.AdvanceAsync();

        Assert.Equal(RecoveryKeyStep.ChooseDevices, step);
        Assert.False(RecoveryKeyFlow.CanKeep(_keys.Reviewed[0]));
        Assert.False(RecoveryKeyFlow.CanKeep(_keys.Reviewed[2]));
        Assert.Equal(
            ["begin replace OLD-KEY", "finish replace DRAFT CCCC,KKKK keep D-LAPTOP"],
            _keys.Calls);
        Assert.Equal(RecoveryKeyStep.Done, flow.Step);
    }

    [Fact]
    public async Task AClosedDialogDropsItsDraftInTheCore()
    {
        var flow = new RecoveryKeyFlow(RecoveryKeyPurpose.SetUp, Flows);
        await flow.StartAsync();

        await flow.DiscardAsync();

        Assert.Equal(["begin genesis", "discard DRAFT"], _keys.Calls);
        Assert.Empty(flow.Groups);
    }

    [Fact]
    public async Task RecoveringClearsTheKeyAndSaysWhenItIsNotTheAccounts()
    {
        var wrong = new RecoverFlow(Flows) { RecoveryKey = "nope" };
        _keys.Fails["recover"] = SyncErrors.Of("keys.recovery_key");
        await wrong.RecoverAsync();
        var right = new RecoverFlow(Flows) { RecoveryKey = FakeKeyFlows.Key };
        await right.RecoverAsync();

        Assert.Equal("keys.recovery_key", wrong.Failure?.Code);
        Assert.False(wrong.IsDone);
        Assert.True(right.IsDone);
        Assert.Empty(right.RecoveryKey);
    }

    [Fact]
    public async Task ANewDeviceShowsTheWordsAndEndsApproved()
    {
        _keys.Sessions.Enqueue(Session(ApprovalPhase.Open.Instance));
        _keys.Sessions.Enqueue(Session(new ApprovalPhase.Compare(["apple", "river", "stone", "cloud", "lamp"])));
        _keys.Sessions.Enqueue(Session(ApprovalPhase.Approved.Instance));
        var polled = new ManualClock();
        using var flow = new ApprovalFlow(Flows, polled.DelayAsync);

        await flow.StartAsync();
        var waiting = flow.Step;
        await polled.TickAsync();
        var words = flow.Words;
        await flow.WordsMatchAsync();

        Assert.Equal(ApprovalStep.Waiting, waiting);
        Assert.Equal(["apple", "river", "stone", "cloud", "lamp"], words);
        Assert.Equal(ApprovalStep.Approved, flow.Step);
        Assert.Empty(flow.Words);
        Assert.Equal(["request approval", "session REQ-NEW", "session REQ-NEW", "confirm REQ-NEW"], _keys.Calls);
    }

    [Fact]
    public async Task WordsThatDifferEndTheSessionAndAClosedOneIsNotCancelledAgain()
    {
        _keys.Sessions.Enqueue(Session(new ApprovalPhase.Compare(["a", "b", "c", "d", "e"])));
        using var flow = new ApprovalFlow(Flows, new ManualClock().DelayAsync, "REQ-OPEN");

        await flow.StartAsync();
        await flow.WordsDifferAsync();
        await flow.CloseAsync();

        Assert.Equal(ApprovalStep.Cancelled, flow.Step);
        Assert.Equal(ApprovalEnd.Mismatch, flow.EndReason);
        Assert.Equal(["session REQ-OPEN", "differ REQ-OPEN"], _keys.Calls);
    }

    [Fact]
    public async Task ClosingARunningSessionCancelsItForTheOtherDeviceToo()
    {
        _keys.Sessions.Enqueue(Session(ApprovalPhase.Chosen.Instance));
        var picked = new ApprovalRequest("REQ-9", "row-9", "Tablet", "ios", DateTimeOffset.UnixEpoch);
        using var flow = new ApprovalFlow(Flows, new ManualClock().DelayAsync, picked);

        var reviewing = flow.Step;
        await flow.ApproveAsync();
        await flow.CloseAsync();

        Assert.Equal(ApprovalStep.Reviewing, reviewing);
        Assert.Equal(ApprovalStep.Cancelled, flow.Step);
        Assert.Equal(["choose REQ-9", "cancel REQ-9"], _keys.Calls);
    }

    [Fact]
    public async Task ARemovalReviewsDevicesAndTeammatesThenSendsTheSeatsFirst()
    {
        var teammate = new ReviewedMember("team_a", "Data", "ACC-2", "Ana", null, false, 3);
        var self = new ReviewedMember("team_a", "Data", "ACC-1", "Me", null, true, 3);
        _keys.Reviewed = [new ReviewedDevice(ThisComputer, true), new ReviewedDevice(Laptop, true)];
        _keys.Members = [self, teammate];
        var flow = new RemovalFlow(Phone, Flows) { RecoveryKey = FakeKeyFlows.Key };

        await flow.AdvanceAsync();
        flow.SetRemoving(teammate, true);
        flow.SetRemoving(self, true);
        await flow.AdvanceAsync();
        var seats = flow.Step;
        var visit = flow.TeamsToVisit;
        await flow.AdvanceAsync();

        Assert.Equal(RemovalStep.Seats, seats);
        Assert.Equal("team_a", Assert.Single(visit).Team);
        Assert.Equal(RemovalStep.Done, flow.Step);
        Assert.Equal(
            [$"begin removal {FakeKeyFlows.Key} D-PHONE", "finish removal REVIEW keep D-LAPTOP remove ACC-2"],
            _keys.Calls);
    }

    [Fact]
    public async Task AFailedRotationAsksForTheRecoveryKeyAgainAndKeepsTheChoices()
    {
        var teammate = new ReviewedMember("team_a", "Data", "ACC-2", "Ana", null, false, 3);
        _keys.Reviewed = [new ReviewedDevice(Laptop, false)];
        _keys.Members = [teammate];
        var flow = new RemovalFlow(Phone, Flows) { RecoveryKey = FakeKeyFlows.Key };
        await flow.AdvanceAsync();
        flow.SetKeep(_keys.Reviewed[0], true);
        _keys.Fails["finish removal"] = SyncErrors.Of("sync.network");

        await flow.AdvanceAsync();
        var failed = (flow.Step, flow.FailedRotation, flow.Failure?.Code);
        flow.RecoveryKey = FakeKeyFlows.Key;
        await flow.AdvanceAsync();

        Assert.Equal((RemovalStep.EnterKey, true, "sync.network"), failed);
        Assert.Equal(RemovalStep.Review, flow.Step);
        Assert.True(flow.Keeps(_keys.Reviewed[0]));
    }

    [Fact]
    public async Task TheDeviceRowGoesBehindAStepUpThatRunsOnceThenTheCallAgain()
    {
        var challenge = new StepUpChallenge(["phr"], TimeSpan.FromMinutes(5));
        var failure = SyncErrors.Of("sync.step_up_required") with { StepUp = challenge };
        _keys.Fails["remove row"] = failure;
        var asked = new List<StepUpChallenge>();
        var page = new AccountKeysPage(Flows, new StepUpRetry(seen =>
        {
            asked.Add(seen);
            return Task.CompletedTask;
        }));

        var removed = await page.RemoveRowAsync(Laptop);
        var gone = await page.RemoveRowAsync(Phone);

        Assert.Null(removed);
        Assert.Null(gone);
        Assert.Equal([challenge], asked);
        Assert.Equal(["remove row row-laptop", "remove row row-laptop"], _keys.Calls);
    }

    [Fact]
    public async Task TheKeysPageListsThisComputerFirstAndReadsRequestsOnlyWhenApproved()
    {
        _keys.Devices = [Phone, Laptop, ThisComputer];
        _keys.Requests = [new ApprovalRequest("REQ-1", null, "Tablet", "ios", DateTimeOffset.UnixEpoch)];
        var page = new AccountKeysPage(Flows, new StepUpRetry(_ => Task.CompletedTask));

        await page.ReloadAsync();
        var devices = page.Devices.Select(device => device.KeyDeviceId).ToList();
        var requests = page.Requests.Count;
        _keys.State = new KeyState.NeedsApproval(null);
        await page.ReloadAsync();

        Assert.Equal(["D-THIS", "D-LAPTOP", "D-PHONE"], devices);
        Assert.Equal(1, requests);
        Assert.Empty(page.Devices);
        Assert.Empty(page.Requests);
        Assert.True(page.ShowsResets);
    }

    [Fact]
    public void ALockedComputerAsksAgainOnlyWhereTheLockLeavesAWayBack()
    {
        Assert.False(AccountKeysPage.CanAskForApproval(SyncLockCause.DeviceRemoved));
        Assert.True(AccountKeysPage.CanAskForApproval(SyncLockCause.OwnAccountReset));
        Assert.False(AccountKeysPage.CanRecover(SyncLockCause.OwnAccountReset));
        Assert.True(AccountKeysPage.CanRecover(SyncLockCause.Unanchored));
    }

    [Fact]
    public async Task AResetIsOfferedByKeyStateAndOnlyItsOwnDeviceFinishesItOnceHeld()
    {
        var now = DateTimeOffset.UnixEpoch.AddDays(8);
        var resets = new ResetKeys(Flows, new StepUpRetry(_ => Task.CompletedTask), () => now);
        _keys.Reset = FakeKeyFlows.Pending("RESET-1", mine: true);
        _keys.Notices =
        [
            new KeyNotice("N-1", new KeyNoticeKind.ResetEnded("RESET-0", ResetState.Cancelled)),
            new KeyNotice("N-2", new KeyNoticeKind.DeviceRemoved("D-X")),
        ];

        await resets.LoadAsync();

        Assert.Equal(ResetKind.KeepScopeKeys, resets.OfferedKind);
        Assert.True(resets.CancelsWithoutRecoveryKey);
        Assert.True(resets.CanActivate(resets.Pending!));
        Assert.False(resets.CanActivate(FakeKeyFlows.Pending("RESET-2", mine: false)));
        Assert.Equal(new ResetNotice("N-1", ResetState.Cancelled, null), Assert.Single(resets.Notices));
    }

    [Fact]
    public async Task AResetProposalChecksTheNewKeyAndStepsUpWhenTheServerAsks()
    {
        var challenge = new StepUpChallenge(["phr"], null);
        _keys.Fails["finish reset"] = SyncErrors.Of("sync.step_up_required") with { StepUp = challenge };
        var steppedUp = 0;
        var proposal = new ResetProposal(ResetKind.StartEmpty, Flows, new StepUpRetry(_ =>
        {
            steppedUp++;
            return Task.CompletedTask;
        }));

        await proposal.BeginAsync();
        proposal.ContinueToTypeBack();
        proposal.SetTyped(0, "CCCC");
        proposal.SetTyped(1, "KKKK");
        await proposal.SubmitAsync();

        Assert.Equal(ResetProposalStep.Done, proposal.Step);
        Assert.Equal(1, steppedUp);
        Assert.Equal(
            ["begin reset StartEmpty", "finish reset DRAFT CCCC,KKKK", "finish reset DRAFT CCCC,KKKK"],
            _keys.Calls);
    }

    [Fact]
    public async Task SignOutErasesTheKeysFirstAndAsksWhenItCannot()
    {
        _keys.Fails["sign out"] = SyncErrors.Of("sync.network");
        var answers = new Queue<KeysSignOutAnswer>([KeysSignOutAnswer.TryAgain, KeysSignOutAnswer.Cancel]);
        var asked = 0;

        var first = await KeysSignOut.RunAsync(Flows, () => true, _ =>
        {
            asked++;
            return Task.FromResult(answers.Dequeue());
        });
        _keys.Fails["sign out"] = SyncErrors.Of("sync.network");
        var anyway = await KeysSignOut.RunAsync(Flows, () => true, _ =>
            Task.FromResult(KeysSignOutAnswer.SignOutAnyway));
        var other = await KeysSignOut.RunAsync(Flows, () => false, _ =>
            Task.FromResult(KeysSignOutAnswer.SignOutAnyway));

        Assert.True(first);
        Assert.Equal(1, asked);
        Assert.True(anyway);
        Assert.False(other);
        Assert.Equal(["sign out keys", "sign out keys", "sign out keys"], _keys.Calls);
    }

    private static ApprovalSession Session(ApprovalPhase phase) =>
        new("REQ-NEW", ApprovalRole.NewDevice, phase, DateTimeOffset.UnixEpoch.AddMinutes(10));

    // Each wait ends when the test says, inside TickAsync, so a poll runs exactly when it should. A wait the flow
    // stopped polling on is left to the collector.
    private sealed class ManualClock
    {
        private TaskCompletionSource _tick = new();

        public Task DelayAsync(TimeSpan span, CancellationToken cancellationToken) => _tick.Task;

        public Task TickAsync()
        {
            var tick = _tick;
            _tick = new TaskCompletionSource();
            tick.SetResult();
            return Task.CompletedTask;
        }
    }
}
