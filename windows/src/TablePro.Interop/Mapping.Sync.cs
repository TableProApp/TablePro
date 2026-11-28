using Native = TablePro.Interop.Native;

namespace TablePro.Interop;

// The sync records; times cross as milliseconds from the Unix epoch.
internal static partial class Mapping
{
    public static Native.SyncConfig Sync(SyncConfiguration configuration) => new(
        Native.SyncPlatformTag.Windows,
        Provider(configuration.Provider),
        Categories(configuration.Categories),
        IcloudAccount: null,
        ServiceAccount: configuration.ServiceAccount,
        // Windows publishes no SSH routes of its own, so it clears none (core ADR 0054, The Apple apps on the engine).
        RoutePublisher: null);

    public static Native.SyncProviderTag Provider(SyncProvider provider) => provider switch
    {
        SyncProvider.Off => Native.SyncProviderTag.Off,
        SyncProvider.TableProSync => Native.SyncProviderTag.TableproSync,
        _ => throw new ArgumentOutOfRangeException(nameof(provider), provider, null),
    };

    public static Native.SyncCategoriesArg Categories(SyncCategories categories) =>
        new([.. categories.OffKinds], categories.Passwords);

    public static Native.PassReasonTag Reason(SyncPassReason why) => why switch
    {
        SyncPassReason.Foreground => Native.PassReasonTag.Foreground,
        SyncPassReason.NetworkBack => Native.PassReasonTag.NetworkBack,
        SyncPassReason.Person => Native.PassReasonTag.Person,
        _ => throw new ArgumentOutOfRangeException(nameof(why), why, null),
    };

    public static SyncStatus Status(Native.SyncStatusInfo status) => new(
        status.Phase switch
        {
            Native.SyncPhaseTag.Off => SyncPhase.Off,
            Native.SyncPhaseTag.Idle => SyncPhase.Idle,
            Native.SyncPhaseTag.Syncing => SyncPhase.Syncing,
            Native.SyncPhaseTag.Waiting => SyncPhase.Waiting,
            Native.SyncPhaseTag.PullOnly => SyncPhase.PullOnly,
            Native.SyncPhaseTag.NewIdentity => SyncPhase.NewIdentity,
            Native.SyncPhaseTag.NeedsApproval => SyncPhase.NeedsApproval,
            // A removed CloudKit zone is iCloud's alone, which Windows never runs.
            _ => SyncPhase.Unavailable,
        },
        status.Phase is Native.SyncPhaseTag.Waiting waiting ? Milliseconds(waiting.RetryInMs) : null,
        status.LastPassMs is { } last ? DateTimeOffset.FromUnixTimeMilliseconds(last) : null,
        status.Problem,
        checked((int)status.WaitingApprovals),
        checked((int)status.Conflicts),
        checked((int)status.Held),
        checked((int)status.QueuedChanges));

    public static SyncScopeStatus Scope(Native.ScopeStatusInfo scope) => new(
        scope.Scope,
        scope.Writable,
        scope.PersonalSync,
        scope.PasswordSync,
        scope.HistorySync);

    public static SyncUploadPlan Plan(Native.MovePlanInfo plan) =>
        new(Count(plan.Records), Count(plan.StayingBehind), Count(plan.SecretsToSeal));

    public static KeyState Keys(Native.KeyStateInfo state) => state switch
    {
        Native.KeyStateInfo.NoDeviceStore => KeyState.NoDeviceStore.Instance,
        Native.KeyStateInfo.NoKeys => KeyState.NoKeys.Instance,
        Native.KeyStateInfo.NeedsApproval approval => new KeyState.NeedsApproval(approval.Request),
        Native.KeyStateInfo.Approved approved => new KeyState.Approved(approved.Av, approved.KeyDevice),
        Native.KeyStateInfo.Locked locked => new KeyState.Locked(Lock(locked.Cause)),
        _ => KeyState.Unknown.Instance,
    };

    public static SyncLockCause Lock(Native.LockCauseTag cause) => cause switch
    {
        Native.LockCauseTag.DeviceRemoved => SyncLockCause.DeviceRemoved,
        Native.LockCauseTag.LeftOutOfRotation => SyncLockCause.LeftOutOfRotation,
        Native.LockCauseTag.OwnAccountReset => SyncLockCause.OwnAccountReset,
        Native.LockCauseTag.AccountEnded => SyncLockCause.AccountEnded,
        Native.LockCauseTag.Unanchored => SyncLockCause.Unanchored,
        _ => SyncLockCause.PersonalStopped,
    };

    public static SyncFailure? Failure(Native.SyncFailureInfo? failure) => failure switch
    {
        Native.SyncFailureInfo.StepUp stepUp =>
            new SyncFailure.StepUp([.. stepUp.AcrValues], TimeSpan.FromSeconds(checked((long)stepUp.MaxAgeSecs))),
        Native.SyncFailureInfo.RetryAfter retry => new SyncFailure.RetryAfter(Milliseconds(retry.Ms)),
        Native.SyncFailureInfo.Rejected rejected => new SyncFailure.Rejected(rejected.Code),
        Native.SyncFailureInfo.Locked locked => new SyncFailure.Locked(Lock(locked.Cause)),
        _ => null,
    };

    private static TimeSpan Milliseconds(ulong milliseconds) => TimeSpan.FromMilliseconds(checked((long)milliseconds));
}
