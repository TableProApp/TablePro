using TablePro.Interop;

namespace TablePro.App.Model.Tests;

public sealed class SyncPaneTests
{
    private static readonly DateTimeOffset Noon = new(2026, 11, 27, 12, 0, 0, TimeSpan.Zero);

    private static readonly SyncStatus Idle = new(SyncPhase.Idle, null, Noon, null, 0, 0, 0, 0);

    private static readonly KeyState Approved = new KeyState.Approved(1, "D");

    [Fact]
    public void AnUnlicensedPcThatIsOffShowsNoSwitchesAndNoGate()
    {
        var pane = Pane(SyncProvider.Off, FeatureAccess.SignedOut);

        Assert.True(pane.OffersTableProSync);
        Assert.False(pane.ShowsGate);
        Assert.False(pane.ShowsCategories);
        Assert.Null(pane.Status);
    }

    [Fact]
    public void TheSwitchesShowBeforeTheFirstUpload()
    {
        var pane = Pane(SyncProvider.Off, FeatureAccess.Available);

        Assert.True(pane.ShowsCategories);
        Assert.False(pane.OffersSyncNow);
    }

    [Fact]
    public void AnUpToDatePcShowsWhenItLastSyncedAndSyncNow()
    {
        var pane = Pane(SyncProvider.TableProSync, FeatureAccess.Available, Idle, Approved);

        Assert.Equal(SyncStatusKind.UpToDate, pane.Status);
        Assert.Equal(Noon, pane.LastPass);
        Assert.True(pane.OffersSyncNow);
        Assert.False(pane.ShowsGate);
        Assert.Null(pane.Notice);
    }

    [Theory]
    [InlineData(SyncPhase.Syncing, SyncStatusKind.Syncing, false)]
    [InlineData(SyncPhase.Waiting, SyncStatusKind.Waiting, true)]
    [InlineData(SyncPhase.PullOnly, SyncStatusKind.DownloadingOnly, true)]
    [InlineData(SyncPhase.Unavailable, SyncStatusKind.Unavailable, true)]
    public void EachPhaseHasItsStatus(SyncPhase phase, SyncStatusKind expected, bool offersSyncNow)
    {
        var status = Idle with { Phase = phase, Problem = phase == SyncPhase.Unavailable ? "sync.network" : null };

        var pane = Pane(SyncProvider.TableProSync, FeatureAccess.Available, status, Approved);

        Assert.Equal(expected, pane.Status);
        Assert.Equal(offersSyncNow, pane.OffersSyncNow);
        Assert.Equal(phase == SyncPhase.Unavailable ? "sync.network" : null, pane.Problem);
    }

    [Fact]
    public void APcWaitingForApprovalSaysSoUnlessAPassRuns()
    {
        var waiting = new KeyState.NeedsApproval("R");

        Assert.Equal(
            SyncStatusKind.NeedsApproval,
            Pane(SyncProvider.TableProSync, FeatureAccess.Available, Idle, waiting).Status);
        Assert.Equal(
            SyncStatusKind.Syncing,
            Pane(SyncProvider.TableProSync, FeatureAccess.Available, Idle with { Phase = SyncPhase.Syncing }, waiting)
                .Status);
        Assert.Equal(
            SyncStatusKind.NeedsRecoveryKey,
            Pane(SyncProvider.TableProSync, FeatureAccess.Available, Idle, KeyState.NoKeys.Instance).Status);
    }

    [Fact]
    public void ALockedPcNamesItsCause()
    {
        var pane = Pane(
            SyncProvider.TableProSync,
            FeatureAccess.Available,
            Idle,
            new KeyState.Locked(SyncLockCause.LeftOutOfRotation));

        Assert.Equal(SyncStatusKind.Locked, pane.Status);
        Assert.Equal(SyncLockCause.LeftOutOfRotation, pane.LockCause);
    }

    [Fact]
    public void AKeyStoreThatHasNotAnsweredIsAWaitNotAFailure()
    {
        var status = Idle with { Phase = SyncPhase.Unavailable, Problem = "sync.device_store.locked" };

        var pane = Pane(SyncProvider.TableProSync, FeatureAccess.Available, status, Approved);

        Assert.Equal(SyncStatusKind.Waiting, pane.Status);
    }

    [Fact]
    public void AServiceThatIsStillOpeningIsStartingAndOneThatFailedSaysWhy()
    {
        var opening = Pane(SyncProvider.TableProSync, FeatureAccess.Available);
        var failed = SyncPane.For(Inputs(SyncProvider.TableProSync, FeatureAccess.Available) with
        {
            OpenFailure = SyncErrors.Of("sync.state.busy"),
        });

        Assert.Equal(SyncStatusKind.Starting, opening.Status);
        Assert.False(opening.OffersSyncNow);
        Assert.Equal(SyncStatusKind.Unavailable, failed.Status);
        Assert.Equal("sync.state.busy", failed.Problem);
    }

    [Fact]
    public void AnotherAccountAsksBeforeAnyStatus()
    {
        var status = Idle with { Phase = SyncPhase.NewIdentity };

        var pane = Pane(SyncProvider.TableProSync, FeatureAccess.Available, status, Approved);

        Assert.Equal(SyncNotice.NewIdentity, pane.Notice);
        Assert.Null(pane.Status);
        Assert.False(pane.OffersSyncNow);
    }

    [Fact]
    public void ALapsedPlanPausesUploadsAndKeepsDownloading()
    {
        var status = Idle with { Phase = SyncPhase.PullOnly };

        var pane = Pane(SyncProvider.TableProSync, FeatureAccess.Expired, status, Approved);

        Assert.Equal(SyncNotice.UploadsPaused, pane.Notice);
        Assert.Equal(SyncStatusKind.DownloadingOnly, pane.Status);
        Assert.True(pane.ShowsGate);
        Assert.True(pane.ShowsCategories);
    }

    [Fact]
    public void APersonalScopeTheServerHoldsReadOnlyPausesUploads()
    {
        var pane = SyncPane.For(Inputs(SyncProvider.TableProSync, FeatureAccess.Available, Idle, Approved) with
        {
            Scopes = [new SyncScopeStatus("personal", false, null, null, null)],
        });

        Assert.Equal(SyncNotice.UploadsPaused, pane.Notice);
    }

    [Fact]
    public void ASignedOutPcOnTableProSyncShowsTheGateInPlaceOfTheStatus()
    {
        var pane = Pane(SyncProvider.TableProSync, FeatureAccess.SignedOut, Idle, Approved);

        Assert.True(pane.ShowsGate);
        Assert.Null(pane.Status);
        Assert.False(pane.ShowsCategories);
    }

    [Fact]
    public void TheServersSwitchesAreSaidAndPersonalSyncOffIsTheOneNotice()
    {
        var history = new SyncScopeStatus("history", true, null, null, false);
        var passwords = new SyncScopeStatus("personal", true, null, false, null);
        var personalOff = new SyncScopeStatus("personal", true, false, false, null);

        Assert.Equal(
            [SyncServerPolicy.PasswordsOff, SyncServerPolicy.HistoryOff],
            SyncPane.ServerPolicies([passwords, history]));
        Assert.Equal([SyncServerPolicy.PersonalSyncOff], SyncPane.ServerPolicies([personalOff, history]));
        var refused = SyncPane.For(Inputs(SyncProvider.TableProSync, FeatureAccess.Available, Idle, Approved) with
        {
            Scopes = [personalOff],
        });
        Assert.Null(refused.Status);
        Assert.True(refused.PasswordsOffOnServer);
        Assert.True(refused.OffersTableProSync);
        Assert.False(SyncPane.For(Inputs(SyncProvider.Off, FeatureAccess.Available) with { Scopes = [personalOff] })
            .OffersTableProSync);
    }

    [Fact]
    public void ThePlanFeatureIsTheMacAppsCode()
    {
        Assert.Equal(PlanFeatures.ServiceSync, SyncPane.Feature);
    }

    private static SyncPane Pane(
        SyncProvider provider,
        FeatureAccess access,
        SyncStatus? status = null,
        KeyState? keys = null) =>
        SyncPane.For(Inputs(provider, access, status, keys));

    private static SyncPaneInputs Inputs(
        SyncProvider provider,
        FeatureAccess access,
        SyncStatus? status = null,
        KeyState? keys = null) =>
        new(provider, access, status, [], keys, null);
}
