using Native = TablePro.Interop.Native;

namespace TablePro.Interop;

// The key flows' records; times cross as microseconds from the Unix epoch.
internal static partial class Mapping
{
    public static RecoveryKeyDraft Draft(Native.RecoveryKeyDraftInfo draft) =>
        new(draft.Draft, draft.Text, [.. draft.Check.Select(group => (int)group)]);

    public static KeyDevice Device(Native.AccountDeviceInfo device) => new(
        device.KeyDevice,
        device.Device,
        device.Name,
        device.Platform,
        device.AddedAtUs is { } added ? Microseconds(added) : null,
        device.ThisDevice,
        device.Compared);

    public static ReviewedDevice Reviewed(Native.ReviewedDeviceInfo reviewed) =>
        new(Device(reviewed.Device), reviewed.KeepByDefault);

    public static ReviewedMember Member(Native.ReviewedMemberInfo member) => new(
        member.Team,
        member.TeamName,
        member.Account,
        member.Name,
        member.Email,
        member.IsSelf,
        member.ConfirmedUnderAv);

    public static Native.ReviewedMemberInfo Member(ReviewedMember member) => new(
        member.Team,
        member.TeamName,
        member.Account,
        member.Name,
        member.Email,
        member.IsSelf,
        checked((uint)member.ConfirmedUnderVersion));

    public static ApprovalRequest Request(Native.ApprovalRequestInfo request) => new(
        request.Request,
        request.Device,
        request.DeviceName,
        request.Platform,
        Microseconds(request.RequestedAtUs));

    public static ApprovalSession Session(Native.ApprovalSessionInfo session) => new(
        session.Request,
        session.Role == Native.SessionRoleTag.Approver ? ApprovalRole.Approver : ApprovalRole.NewDevice,
        session.Phase switch
        {
            Native.SessionPhaseTag.Open => ApprovalPhase.Open.Instance,
            Native.SessionPhaseTag.Chosen => ApprovalPhase.Chosen.Instance,
            Native.SessionPhaseTag.Compare compare => new ApprovalPhase.Compare([.. compare.Words]),
            Native.SessionPhaseTag.Confirmed => ApprovalPhase.Confirmed.Instance,
            Native.SessionPhaseTag.Approved => ApprovalPhase.Approved.Instance,
            Native.SessionPhaseTag.TakenElsewhere => ApprovalPhase.TakenElsewhere.Instance,
            Native.SessionPhaseTag.Cancelled cancelled => new ApprovalPhase.Cancelled(End(cancelled.Reason)),
            _ => ApprovalPhase.Expired.Instance,
        },
        Microseconds(session.ExpiresAtUs));

    public static PendingReset Reset(Native.PendingResetInfo reset) => new(
        reset.Reset,
        reset.Kind == Native.ResetKindTag.StartEmpty ? ResetKind.StartEmpty : ResetKind.KeepScopeKeys,
        State(reset.State),
        reset.Mine,
        reset.ProposedBy,
        Microseconds(reset.TakenAtUs),
        Microseconds(reset.HeldUntilUs));

    public static Native.ResetKindTag Reset(ResetKind kind) => kind switch
    {
        ResetKind.KeepScopeKeys => Native.ResetKindTag.KeepScopeKeys,
        ResetKind.StartEmpty => Native.ResetKindTag.StartEmpty,
        _ => throw new ArgumentOutOfRangeException(nameof(kind), kind, null),
    };

    public static KeyFingerprint Fingerprint(Native.FingerprintInfo fingerprint) =>
        new([.. fingerprint.Words], fingerprint.Qr);

    public static KeyNotice Notice(Native.KeyNoticeInfo notice) => new(notice.Id, notice.Kind switch
    {
        Native.KeyNoticeKindTag.RecoveryKeyReplaced replaced => new KeyNoticeKind.RecoveryKeyReplaced(replaced.Account),
        Native.KeyNoticeKindTag.KeysChanged changed => new KeyNoticeKind.KeysChanged(changed.Account),
        Native.KeyNoticeKindTag.TeamKeyRestarted restarted => new KeyNoticeKind.TeamKeyRestarted(restarted.Team),
        Native.KeyNoticeKindTag.RestartHeld held => new KeyNoticeKind.RestartHeld(held.Team, held.Signer),
        Native.KeyNoticeKindTag.ResetPending pending => new KeyNoticeKind.ResetPending(pending.Reset),
        Native.KeyNoticeKindTag.ResetWaitsForStepUp waits => new KeyNoticeKind.ResetWaitsForStepUp(waits.Reset),
        Native.KeyNoticeKindTag.ResetEnded ended => new KeyNoticeKind.ResetEnded(ended.Reset, State(ended.State)),
        Native.KeyNoticeKindTag.DeviceRemoved removed => new KeyNoticeKind.DeviceRemoved(removed.Device),
        Native.KeyNoticeKindTag.SupersededWrap superseded => new KeyNoticeKind.SupersededWrap(superseded.Team),
        Native.KeyNoticeKindTag.Conflict conflict => new KeyNoticeKind.Conflict(conflict.Scope),
        Native.KeyNoticeKindTag.ScopeStopped stopped => new KeyNoticeKind.ScopeStopped(stopped.Scope, Stop(stopped.Cause)),
        Native.KeyNoticeKindTag.ScopeEnded ended => new KeyNoticeKind.ScopeEnded(ended.Scope),
        Native.KeyNoticeKindTag.Locked locked => new KeyNoticeKind.Locked(Lock(locked.Cause)),
        _ => throw new ArgumentOutOfRangeException(nameof(notice), notice.Kind, null),
    });

    public static StopCause Stop(Native.StopCauseTag cause) => cause switch
    {
        Native.StopCauseTag.CatchUp => StopCause.CatchUp,
        Native.StopCauseTag.RestoreWait => StopCause.RestoreWait,
        _ => StopCause.RestartHeld,
    };

    private static ResetState State(Native.ResetStateTag state) => state switch
    {
        Native.ResetStateTag.Pending => ResetState.Pending,
        Native.ResetStateTag.Cancelled => ResetState.Cancelled,
        Native.ResetStateTag.Superseded => ResetState.Superseded,
        _ => ResetState.Active,
    };

    private static ApprovalEnd End(Native.SessionEndTag reason) => reason switch
    {
        Native.SessionEndTag.Mismatch => ApprovalEnd.Mismatch,
        Native.SessionEndTag.Commitment => ApprovalEnd.Commitment,
        _ => ApprovalEnd.User,
    };

    private static DateTimeOffset Microseconds(long microseconds) =>
        DateTimeOffset.UnixEpoch.AddTicks(checked(microseconds * TimeSpan.TicksPerMicrosecond));
}
