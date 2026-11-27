using System.Globalization;
using TablePro.App.Model;
using TablePro.Interop;

namespace TablePro.App.Services;

// The end-to-end encryption screens in words, worded as the macOS app's AccountKeysText and its sheets word them.
internal static class KeysText
{
    public static string DeviceName(string? name) =>
        string.IsNullOrWhiteSpace(name) ? Strings.Get("KeysUnnamedDevice") : name;

    public static string? Platform(string? platform) => string.IsNullOrWhiteSpace(platform)
        ? null
        : Strings.Get("DevicePlatform_" + platform.ToLowerInvariant()) is { Length: > 0 } named ? named : platform;

    // "This computer", or the platform and when it joined.
    public static string DeviceDetail(KeyDevice device)
    {
        ArgumentNullException.ThrowIfNull(device);
        if (device.IsThisDevice)
        {
            return Strings.Get("DeviceThisComputer");
        }

        var platform = Platform(device.Platform);
        var added = device.AddedAt is { } at ? Strings.Format("KeysDeviceAdded", at.LocalDateTime) : null;
        return Strings.List(new[] { platform, added }.OfType<string>());
    }

    public static string KeepDetail(ReviewedDevice device)
    {
        ArgumentNullException.ThrowIfNull(device);
        if (device.Device.IsThisDevice)
        {
            return Strings.Get("DeviceThisComputer");
        }

        var how = Strings.Get(device.Device.Compared ? "KeysCompared" : "KeysAsksAgain");
        return Strings.List(new[] { Platform(device.Device.Platform), how }.OfType<string>());
    }

    public static string Member(ReviewedMember member)
    {
        ArgumentNullException.ThrowIfNull(member);
        if (member.IsSelf)
        {
            return Strings.Get("KeysYou");
        }

        return member.Name ?? member.Email ?? Strings.Get("KeysUnnamedTeammate");
    }

    public static string Team(string? name) => string.IsNullOrWhiteSpace(name) ? Strings.Get("KeysUnnamedTeam") : name;

    // "Type groups 3 and 10 of your recovery key."
    public static string TypeBack(IReadOnlyList<int> check)
    {
        ArgumentNullException.ThrowIfNull(check);
        return check.Count == 2
            ? Strings.Format("KeysTypeBackGroups", check[0] + 1, check[1] + 1)
            : Strings.Get("KeysTypeBack");
    }

    public static string Group(int index) => Strings.Format("KeysGroup", index + 1);

    public static string ApprovalTitle(ApprovalFlow flow, string other)
    {
        ArgumentNullException.ThrowIfNull(flow);
        var mine = flow.Role == ApprovalRole.NewDevice;
        return flow.Step switch
        {
            ApprovalStep.Reviewing => Strings.Format("KeysApproveTitle", other),
            ApprovalStep.Starting => Strings.Get(mine ? "KeysAskingTitle" : "KeysStartingTitle"),
            ApprovalStep.Waiting => Strings.Get("KeysWaitingTitle"),
            ApprovalStep.Chosen when mine => Strings.Get("KeysChosenTitle"),
            ApprovalStep.Chosen => Strings.Format("KeysWaitingForTitle", other),
            ApprovalStep.Compare => Strings.Get("KeysCompareTitle"),
            ApprovalStep.Confirmed => Strings.Get("KeysConfirmedTitle"),
            ApprovalStep.Approved when mine => Strings.Get("KeysApprovedTitle"),
            ApprovalStep.Approved => Strings.Format("KeysOtherApprovedTitle", other),
            ApprovalStep.TakenElsewhere => Strings.Get("KeysTakenElsewhereTitle"),
            ApprovalStep.Cancelled when flow.EndReason == ApprovalEnd.Mismatch => Strings.Get("KeysMismatchTitle"),
            ApprovalStep.Cancelled when flow.EndReason == ApprovalEnd.Commitment => Strings.Get("KeysCommitmentTitle"),
            ApprovalStep.Cancelled => Strings.Get("KeysCancelledTitle"),
            ApprovalStep.Expired => Strings.Get("KeysExpiredTitle"),
            _ => Strings.Get("KeysFailedTitle"),
        };
    }

    public static string ApprovalMessage(ApprovalFlow flow, string other)
    {
        ArgumentNullException.ThrowIfNull(flow);
        var mine = flow.Role == ApprovalRole.NewDevice;
        return flow.Step switch
        {
            ApprovalStep.Reviewing => Strings.Get("KeysApproveMessage"),
            ApprovalStep.Starting => string.Empty,
            ApprovalStep.Waiting => Strings.Get("KeysWaitingMessage"),
            ApprovalStep.Chosen => Strings.Get("KeysChosenMessage"),
            ApprovalStep.Compare when mine => Strings.Get("KeysCompareMessage"),
            ApprovalStep.Compare => Strings.Format("KeysCompareOtherMessage", other),
            ApprovalStep.Confirmed => Strings.Get("KeysConfirmedMessage"),
            ApprovalStep.Approved when mine => Strings.Get("KeysApprovedMessage"),
            ApprovalStep.Approved => Strings.Get("KeysOtherApprovedMessage"),
            ApprovalStep.TakenElsewhere => Strings.Format("KeysTakenElsewhereMessage", other),
            ApprovalStep.Cancelled when flow.EndReason == ApprovalEnd.Mismatch => Strings.Get("KeysMismatchMessage"),
            ApprovalStep.Cancelled when flow.EndReason == ApprovalEnd.Commitment => Strings.Get("KeysCommitmentMessage"),
            ApprovalStep.Cancelled => Strings.Get("KeysCancelledMessage"),
            ApprovalStep.Expired => Strings.Get("KeysExpiredMessage"),
            _ => flow.Failure is { } failure ? Strings.Error(failure) : string.Empty,
        };
    }

    // How long the request has left, as the person reads a countdown.
    public static string TimeLeft(DateTimeOffset expiresAt, DateTimeOffset now)
    {
        var left = expiresAt - now;
        if (left < TimeSpan.Zero)
        {
            left = TimeSpan.Zero;
        }

        return Strings.Format("KeysTimeLeft", left.ToString(@"m\:ss", CultureInfo.CurrentCulture));
    }

    public static string ResetNoticeText(ResetNotice notice)
    {
        ArgumentNullException.ThrowIfNull(notice);
        return notice.WaitsForStepUp is not null
            ? Strings.Get("KeysResetWaitsForStepUp")
            : Strings.Get("KeysResetEnded_" + (notice.Ended ?? ResetState.Pending));
    }

    public static string PendingResetText(PendingReset reset)
    {
        ArgumentNullException.ThrowIfNull(reset);
        return reset.Mine
            ? Strings.Format("KeysResetMine", reset.HeldUntil.LocalDateTime)
            : Strings.Format("KeysResetOther", DeviceName(reset.ProposedBy), reset.HeldUntil.LocalDateTime);
    }
}
