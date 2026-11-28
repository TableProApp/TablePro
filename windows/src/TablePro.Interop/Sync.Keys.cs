using Native = TablePro.Interop.Native;

namespace TablePro.Interop;

// The recovery key shown once, as 14 groups joined by '-', and the two groups, counted from 0, the person types back.
public sealed record RecoveryKeyDraft(string Draft, string Text, IReadOnlyList<int> Check);

public enum GenesisOutcome
{
    Created,

    // Another device set the account's keys up first, so this one asks it for approval instead.
    AnotherDeviceWon,
}

public enum KeysSignOutOutcome
{
    Revoked,

    // Offline: the keys were erased here, and the server hears it at the next sign-in.
    ErasedOffline,
}

// A device holding the account's keys. Device is its account device row, null once that row is gone; Compared says
// this device compared words with it, which a rotation needs to keep it.
public sealed record KeyDevice(
    string KeyDeviceId,
    string? Device,
    string? Name,
    string? Platform,
    DateTimeOffset? AddedAt,
    bool IsThisDevice,
    bool Compared);

public sealed record ReviewedDevice(KeyDevice Device, bool KeepByDefault);

// A teammate confirmed under this account's keys, whom a removal may leave out of the next team keys.
public sealed record ReviewedMember(
    string Team,
    string? TeamName,
    string Account,
    string? Name,
    string? Email,
    bool IsSelf,
    long ConfirmedUnderVersion);

public sealed record RemovalReview(string Review, IReadOnlyList<ReviewedDevice> Devices, IReadOnlyList<ReviewedMember> Members);

public sealed record RotationDraft(RecoveryKeyDraft Recovery, IReadOnlyList<ReviewedDevice> Devices);

public sealed record ApprovalRequest(
    string Request,
    string? Device,
    string? DeviceName,
    string? Platform,
    DateTimeOffset RequestedAt);

public enum ApprovalRole
{
    NewDevice,
    Approver,
}

public enum ApprovalEnd
{
    User,
    Mismatch,
    Commitment,
}

public abstract record ApprovalPhase
{
    private ApprovalPhase()
    {
    }

    public sealed record Open : ApprovalPhase
    {
        public static Open Instance { get; } = new();
    }

    public sealed record Chosen : ApprovalPhase
    {
        public static Chosen Instance { get; } = new();
    }

    // The five words, shown once per session.
    public sealed record Compare(IReadOnlyList<string> Words) : ApprovalPhase;

    public sealed record Confirmed : ApprovalPhase
    {
        public static Confirmed Instance { get; } = new();
    }

    public sealed record Approved : ApprovalPhase
    {
        public static Approved Instance { get; } = new();
    }

    // Another approved device took the request.
    public sealed record TakenElsewhere : ApprovalPhase
    {
        public static TakenElsewhere Instance { get; } = new();
    }

    public sealed record Cancelled(ApprovalEnd Reason) : ApprovalPhase;

    public sealed record Expired : ApprovalPhase
    {
        public static Expired Instance { get; } = new();
    }
}

public sealed record ApprovalSession(string Request, ApprovalRole Role, ApprovalPhase Phase, DateTimeOffset ExpiresAt);

public enum ResetKind
{
    // From an approved device: the account's keys start again and the scope keys stay.
    KeepScopeKeys,

    // From a device that is not approved: everything sealed so far is left behind.
    StartEmpty,
}

public enum ResetState
{
    Pending,
    Cancelled,
    Superseded,
    Active,
}

// A reset held until HeldUntil, which any device certified at the current keys, or the recovery key, can cancel.
public sealed record PendingReset(
    string Reset,
    ResetKind Kind,
    ResetState State,
    bool Mine,
    string? ProposedBy,
    DateTimeOffset TakenAt,
    DateTimeOffset HeldUntil);

public sealed record KeyFingerprint(IReadOnlyList<string> Words, string Qr);

// An account whose identity key changed from the one pinned here: the two to compare before the new one is trusted.
public sealed record KeyChange(string Account, KeyFingerprint Pinned, KeyFingerprint Offered, string OfferedIdentityKey);

public enum StopCause
{
    CatchUp,
    RestoreWait,
    RestartHeld,
}

public abstract record KeyNoticeKind
{
    private KeyNoticeKind()
    {
    }

    public sealed record RecoveryKeyReplaced(string Account) : KeyNoticeKind;

    public sealed record KeysChanged(string Account) : KeyNoticeKind;

    public sealed record TeamKeyRestarted(string Team) : KeyNoticeKind;

    public sealed record RestartHeld(string Team, string Signer) : KeyNoticeKind;

    public sealed record ResetPending(string Reset) : KeyNoticeKind;

    // A reset a server restore lost, proposed again only after a fresh step-up (core ADR 0065).
    public sealed record ResetWaitsForStepUp(string Reset) : KeyNoticeKind;

    public sealed record ResetEnded(string Reset, ResetState State) : KeyNoticeKind;

    public sealed record DeviceRemoved(string Device) : KeyNoticeKind;

    public sealed record SupersededWrap(string Team) : KeyNoticeKind;

    public sealed record Conflict(string Scope) : KeyNoticeKind;

    public sealed record ScopeStopped(string Scope, StopCause Cause) : KeyNoticeKind;

    public sealed record ScopeEnded(string Scope) : KeyNoticeKind;

    public sealed record Locked(SyncLockCause Cause) : KeyNoticeKind;
}

public sealed record KeyNotice(string Id, KeyNoticeKind Kind);

// The end-to-end key flows a person starts (core ADR 0056). Ids cross as upper-case UUID text, a team as its scope name
// and an identity key as base64url; a recovery key is a string only while a flow holds it.
public sealed partial class TableProSync
{
    public async Task<RecoveryKeyDraft> BeginGenesisAsync() =>
        Mapping.Draft(await CoreCall.RunAsync(() => _service.BeginGenesis()).ConfigureAwait(false));

    // Typed holds the two groups in the order the draft's Check named them.
    public async Task<GenesisOutcome> FinishGenesisAsync(string draft, IReadOnlyList<string> typed)
    {
        ArgumentException.ThrowIfNullOrEmpty(draft);
        ArgumentNullException.ThrowIfNull(typed);
        var groups = typed.ToArray();
        var outcome = await CoreCall.RunAsync(() => _service.FinishGenesis(draft, groups)).ConfigureAwait(false);
        return outcome == Native.GenesisOutcomeTag.AnotherDeviceWon ? GenesisOutcome.AnotherDeviceWon : GenesisOutcome.Created;
    }

    // A sheet closed: its draft goes, and the recovery key it held with it.
    public void DiscardKeyDraft(string draft)
    {
        ArgumentException.ThrowIfNullOrEmpty(draft);
        CoreCall.Run(() => _service.DiscardKeyDraft(draft));
    }

    // Before the account signs out: this device's key device is revoked and its keys erased.
    public async Task<KeysSignOutOutcome> SignOutKeysAsync()
    {
        var outcome = await CoreCall.RunAsync(() => _service.SignOutKeys()).ConfigureAwait(false);
        return outcome == Native.SignOutOutcomeTag.ErasedOffline ? KeysSignOutOutcome.ErasedOffline : KeysSignOutOutcome.Revoked;
    }

    // The new recovery key and the devices the rotation can keep.
    public async Task<RotationDraft> BeginReplaceRecoveryKeyAsync(string recoveryKey)
    {
        ArgumentException.ThrowIfNullOrEmpty(recoveryKey);
        var draft = await CoreCall.RunAsync(() => _service.BeginReplaceRecoveryKey(recoveryKey)).ConfigureAwait(false);
        return new RotationDraft(Mapping.Draft(draft.Recovery), [.. draft.Devices.Select(Mapping.Reviewed)]);
    }

    // Keep holds the key device ids the person ticked.
    public Task FinishReplaceRecoveryKeyAsync(string draft, IReadOnlyList<string> typed, IReadOnlyList<string> keep)
    {
        ArgumentException.ThrowIfNullOrEmpty(draft);
        ArgumentNullException.ThrowIfNull(typed);
        ArgumentNullException.ThrowIfNull(keep);
        var (groups, kept) = (typed.ToArray(), keep.ToArray());
        return CoreCall.RunAsync(() => _service.FinishReplaceRecoveryKey(draft, groups, kept));
    }

    public async Task<IReadOnlyList<KeyNotice>> GetKeyNoticesAsync() =>
        [.. (await CoreCall.RunAsync(() => _service.KeyNotices()).ConfigureAwait(false)).Select(Mapping.Notice)];

    public Task DismissKeyNoticeAsync(string notice)
    {
        ArgumentException.ThrowIfNullOrEmpty(notice);
        return CoreCall.RunAsync(() => _service.DismissKeyNotice(notice));
    }

    // The pinned and the offered identity of an account under a key-change notice, null when none is pending.
    public async Task<KeyChange?> GetKeyChangeAsync(string account)
    {
        ArgumentException.ThrowIfNullOrEmpty(account);
        var change = await CoreCall.RunAsync(() => _service.AccountKeyChange(account)).ConfigureAwait(false);
        return change is null
            ? null
            : new KeyChange(change.Account, Mapping.Fingerprint(change.Pinned), Mapping.Fingerprint(change.Offered), change.OfferedIk);
    }

    // OfferedIdentityKey is the one GetKeyChangeAsync showed. Accepting without comparing is recorded as such.
    public Task AcceptKeyChangeAsync(string account, string offeredIdentityKey, bool compared)
    {
        ArgumentException.ThrowIfNullOrEmpty(account);
        ArgumentException.ThrowIfNullOrEmpty(offeredIdentityKey);
        return CoreCall.RunAsync(() => _service.AcceptKeyChange(account, offeredIdentityKey, compared));
    }

    // This device's request, as the new device; the approver picks it from GetApprovalRequestsAsync.
    public Task<string> RequestApprovalAsync() => CoreCall.RunAsync(() => _service.RequestApproval());

    public async Task<IReadOnlyList<ApprovalRequest>> GetApprovalRequestsAsync() =>
        [.. (await CoreCall.RunAsync(() => _service.ApprovalRequests()).ConfigureAwait(false)).Select(Mapping.Request)];

    // The approver commits to a request; the session is held by this device from then on.
    public Task<ApprovalSession> ChooseApprovalRequestAsync(string request) =>
        SessionAsync(request, () => _service.ChooseApprovalRequest(request));

    public Task<ApprovalSession> GetApprovalSessionAsync(string request) =>
        SessionAsync(request, () => _service.ApprovalSession(request));

    // The words match on both screens.
    public Task<ApprovalSession> ConfirmApprovalSessionAsync(string request) =>
        SessionAsync(request, () => _service.ConfirmApprovalSession(request));

    public Task ApprovalWordsDifferAsync(string request)
    {
        ArgumentException.ThrowIfNullOrEmpty(request);
        return CoreCall.RunAsync(() => _service.ApprovalWordsDiffer(request));
    }

    public Task CancelApprovalSessionAsync(string request)
    {
        ArgumentException.ThrowIfNullOrEmpty(request);
        return CoreCall.RunAsync(() => _service.CancelApprovalSession(request));
    }

    public async Task<IReadOnlyList<KeyDevice>> GetAccountDevicesAsync() =>
        [.. (await CoreCall.RunAsync(() => _service.AccountDevices()).ConfigureAwait(false)).Select(Mapping.Device)];

    // A device's account row goes first, behind a fresh step-up: sync.step_up_required carries the challenge until then.
    public Task RemoveDeviceRowAsync(string device)
    {
        ArgumentException.ThrowIfNullOrEmpty(device);
        return CoreCall.RunAsync(() => _service.RemoveDeviceRow(device));
    }

    // The recovery key, then the devices to keep and the teammates to leave out of the next keys.
    public async Task<RemovalReview> BeginDeviceRemovalAsync(string recoveryKey, IReadOnlyList<string> lost)
    {
        ArgumentException.ThrowIfNullOrEmpty(recoveryKey);
        ArgumentNullException.ThrowIfNull(lost);
        var devices = lost.ToArray();
        var review = await CoreCall.RunAsync(() => _service.BeginDeviceRemoval(recoveryKey, devices)).ConfigureAwait(false);
        return new RemovalReview(
            review.Review,
            [.. review.Devices.Select(Mapping.Reviewed)],
            [.. review.Members.Select(Mapping.Member)]);
    }

    public Task FinishDeviceRemovalAsync(string review, IReadOnlyList<string> keep, IReadOnlyList<ReviewedMember> remove)
    {
        ArgumentException.ThrowIfNullOrEmpty(review);
        ArgumentNullException.ThrowIfNull(keep);
        ArgumentNullException.ThrowIfNull(remove);
        var kept = keep.ToArray();
        Native.ReviewedMemberInfo[] removed = [.. remove.Select(Mapping.Member)];
        return CoreCall.RunAsync(() => _service.FinishDeviceRemoval(review, kept, removed));
    }

    // With no approved device at hand: this device is kept alone, and every other one asks it for approval after.
    public Task RecoverWithRecoveryKeyAsync(string recoveryKey)
    {
        ArgumentException.ThrowIfNullOrEmpty(recoveryKey);
        return CoreCall.RunAsync(() => _service.RecoverWithRecoveryKey(recoveryKey));
    }

    public async Task<PendingReset?> GetPendingResetAsync()
    {
        var reset = await CoreCall.RunAsync(() => _service.PendingReset()).ConfigureAwait(false);
        return reset is null ? null : Mapping.Reset(reset);
    }

    public async Task<RecoveryKeyDraft> BeginResetAsync(ResetKind kind)
    {
        var native = Mapping.Reset(kind);
        return Mapping.Draft(await CoreCall.RunAsync(() => _service.BeginReset(native)).ConfigureAwait(false));
    }

    public async Task<PendingReset> FinishResetProposalAsync(string draft, IReadOnlyList<string> typed)
    {
        ArgumentException.ThrowIfNullOrEmpty(draft);
        ArgumentNullException.ThrowIfNull(typed);
        var groups = typed.ToArray();
        return Mapping.Reset(await CoreCall.RunAsync(() => _service.FinishResetProposal(draft, groups)).ConfigureAwait(false));
    }

    // With no recovery key, this device cancels as one certified at the current keys.
    public Task CancelResetAsync(string reset, string? recoveryKey)
    {
        ArgumentException.ThrowIfNullOrEmpty(reset);
        return CoreCall.RunAsync(() => _service.CancelReset(reset, recoveryKey));
    }

    public Task ActivateResetAsync(string reset)
    {
        ArgumentException.ThrowIfNullOrEmpty(reset);
        return CoreCall.RunAsync(() => _service.ActivateReset(reset));
    }

    // A reset a server restore lost, proposed again after a fresh step-up, as the ResetWaitsForStepUp notice asks.
    public Task ResumeResetAsync(string reset)
    {
        ArgumentException.ThrowIfNullOrEmpty(reset);
        return CoreCall.RunAsync(() => _service.ResumeReset(reset));
    }

    private static async Task<ApprovalSession> SessionAsync(string request, Func<Task<Native.ApprovalSessionInfo>> call)
    {
        ArgumentException.ThrowIfNullOrEmpty(request);
        return Mapping.Session(await CoreCall.RunAsync(call).ConfigureAwait(false));
    }
}
