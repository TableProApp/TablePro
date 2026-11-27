using TablePro.Interop;

namespace TablePro.App.Model;

// A server switch that keeps something off TablePro Sync while this PC is signed in to it (core ADR 0051, Policies).
public enum SyncServerPolicy
{
    // No personal data at all; the team scopes and the account's keys go on.
    PersonalSyncOff,
    PasswordsOff,
    HistoryOff,
}

// A state stated at length above the provider, beyond the status.
public enum SyncNotice
{
    // Another account or server waits for Move my data or Start empty (core ADR 0054, Another account or server).
    NewIdentity,

    // Past the license's grace or after a lapse the server takes key objects only (core ADR 0051, Gates).
    UploadsPaused,
}

public enum SyncStatusKind
{
    Starting,
    UpToDate,
    Syncing,
    Waiting,
    DownloadingOnly,

    // This PC waits for another device to approve it, or for the recovery key (core ADR 0056).
    NeedsApproval,

    // The account has no keys yet, so its recovery key is set up first.
    NeedsRecoveryKey,
    Locked,
    Off,
    Unavailable,
}

public sealed record SyncPaneInputs(
    SyncProvider Provider,
    // The core's answer for service_sync; null while the account is not open.
    FeatureAccess? Access,
    SyncStatus? Status,
    IReadOnlyList<SyncScopeStatus> Scopes,
    KeyState? Keys,
    CoreError? OpenFailure);

// What Settings' Sync section shows, as the macOS app's SyncPaneLayout decides it for TablePro Sync, so the section's
// rules are tested without a window.
public sealed record SyncPane(
    bool OffersTableProSync,
    // The license gate's notice stands in place of the status (docs/decisions/0023).
    bool ShowsGate,
    SyncNotice? Notice,
    SyncStatusKind? Status,
    // The code that explains the status, which the page words.
    string? Problem,
    SyncLockCause? LockCause,
    DateTimeOffset? LastPass,
    bool OffersSyncNow,
    bool ShowsCategories,
    IReadOnlyList<SyncServerPolicy> ServerPolicies)
{
    public const string Feature = "service_sync";

    // Passwords on this server stay on this PC, so the switch has nothing to turn on.
    public bool PasswordsOffOnServer =>
        ServerPolicies.Contains(SyncServerPolicy.PasswordsOff)
        || ServerPolicies.Contains(SyncServerPolicy.PersonalSyncOff);

    public static SyncPane For(SyncPaneInputs inputs)
    {
        ArgumentNullException.ThrowIfNull(inputs);
        var policies = ServerPolicies(inputs.Scopes);
        var refused = policies.Contains(SyncServerPolicy.PersonalSyncOff);
        // Past the grace the service still serves pulls, so the provider stays and says so.
        var licensed = inputs.Access is FeatureAccess.Available or FeatureAccess.Expired;
        if (inputs.Provider == SyncProvider.Off)
        {
            // The server's switch takes TablePro Sync away as a new choice, and never moves a PC already on it. The
            // switches apply before the first upload, so they show while sync is off too.
            return new SyncPane(!refused, false, null, null, null, null, null, false, licensed, []);
        }

        var newIdentity = inputs.Status?.Phase == SyncPhase.NewIdentity;
        var writable = inputs.Scopes.FirstOrDefault(scope => scope.Scope == "personal")?.Writable ?? true;
        var pullOnly = inputs.Status?.Phase == SyncPhase.PullOnly
            || inputs.Access == FeatureAccess.Expired
            || !writable;
        SyncNotice? notice = newIdentity
            ? SyncNotice.NewIdentity
            : licensed && !refused && pullOnly ? SyncNotice.UploadsPaused : null;
        var live = licensed && !newIdentity && !refused;
        var (status, problem) = live ? StatusOf(inputs) : default;
        return new SyncPane(
            true,
            inputs.Access != FeatureAccess.Available,
            notice,
            status,
            problem,
            status == SyncStatusKind.Locked && inputs.Keys is KeyState.Locked locked ? locked.Cause : null,
            live ? inputs.Status?.LastPass : null,
            live && status is not (SyncStatusKind.Syncing or SyncStatusKind.Starting),
            licensed,
            policies);
    }

    // personal_sync off holds the history too, so it is the one notice then.
    public static IReadOnlyList<SyncServerPolicy> ServerPolicies(IReadOnlyList<SyncScopeStatus> scopes)
    {
        ArgumentNullException.ThrowIfNull(scopes);
        var personal = scopes.FirstOrDefault(scope => scope.Scope == "personal");
        var history = scopes.FirstOrDefault(scope => scope.Scope == "history");
        if (personal?.PersonalSync == false || history?.PersonalSync == false)
        {
            return [SyncServerPolicy.PersonalSyncOff];
        }

        var policies = new List<SyncServerPolicy>();
        if (personal?.PasswordSync == false)
        {
            policies.Add(SyncServerPolicy.PasswordsOff);
        }

        if (history?.HistorySync == false)
        {
            policies.Add(SyncServerPolicy.HistoryOff);
        }

        return policies;
    }

    private static (SyncStatusKind? Status, string? Problem) StatusOf(SyncPaneInputs inputs)
    {
        if (inputs.OpenFailure is { } failure)
        {
            return (SyncStatusKind.Unavailable, failure.Code);
        }

        // Opened once the account has read what this PC holds, so a launch shows it starting first.
        if (inputs.Status is not { } status)
        {
            return (SyncStatusKind.Starting, null);
        }

        if (status.Phase == SyncPhase.Syncing)
        {
            return (SyncStatusKind.Syncing, null);
        }

        switch (inputs.Keys)
        {
            case KeyState.Locked:
                return (SyncStatusKind.Locked, null);
            case KeyState.NeedsApproval:
                return (SyncStatusKind.NeedsApproval, null);
            case KeyState.NoKeys:
                return (SyncStatusKind.NeedsRecoveryKey, null);
            case KeyState.NoDeviceStore:
                return (SyncStatusKind.Unavailable, "sync.device_store.unavailable");
        }

        // A key store that has not answered yet is a wait the core retries on its own, never a failure.
        if (status.Problem == "sync.device_store.locked")
        {
            return (SyncStatusKind.Waiting, status.Problem);
        }

        return status.Phase switch
        {
            SyncPhase.Idle => (SyncStatusKind.UpToDate, null),
            SyncPhase.Waiting => (SyncStatusKind.Waiting, status.Problem),
            SyncPhase.PullOnly => (SyncStatusKind.DownloadingOnly, null),
            SyncPhase.Off => (SyncStatusKind.Off, null),
            _ => (SyncStatusKind.Unavailable, status.Problem),
        };
    }
}

// What the upload dialog asks for before anything goes up (core ADR 0055, PersonalSyncProvider; 0056).
public enum UploadKeysStep
{
    SetUpRecoveryKey,
    ApproveThisPc,
    Locked,
    NoDeviceStore,
}

public static class UploadKeys
{
    public static UploadKeysStep? StepFor(KeyState state) => state switch
    {
        KeyState.Approved => null,
        KeyState.NeedsApproval => UploadKeysStep.ApproveThisPc,
        KeyState.Locked => UploadKeysStep.Locked,
        KeyState.NoDeviceStore => UploadKeysStep.NoDeviceStore,
        _ => UploadKeysStep.SetUpRecoveryKey,
    };
}
