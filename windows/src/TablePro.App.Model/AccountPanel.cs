using TablePro.Interop;

namespace TablePro.App.Model;

public enum AccountStage
{
    // The account could not start, as when the machine has no ID; Settings says why.
    Unavailable,
    SignedOut,

    // Waiting for the browser; Cancel ends the wait.
    SigningIn,
    SignedIn,

    // An imported offline file on a machine that is not signed in.
    Offline,
}

public enum AccountNoticeKind
{
    Expired,
    RefreshFailed,
    DeviceLimitReached,

    // No secret store took the sign-in, so the next launch starts signed out.
    NotRemembered,
}

// Code is the error the last refresh met, for RefreshFailed.
public sealed record AccountNotice(AccountNoticeKind Kind, string? Code = null);

// What Settings shows for the TablePro account.
public sealed record AccountPanel(
    AccountStage Stage,
    string? Title,
    string? Email,
    bool IsPro,
    AccountNotice? Notice,
    IReadOnlyList<AccountDevice> LimitDevices)
{
    // The feature the server resolves for Pro, a seated team member's included (share links PLAN, Decisions).
    public const string ProFeature = "shared_links";

    public static AccountPanel Unavailable { get; } = new(AccountStage.Unavailable, null, null, false, null, []);

    public static AccountPanel For(AccountStatus status, bool signingIn)
    {
        ArgumentNullException.ThrowIfNull(status);
        var stage = status.State switch
        {
            _ when signingIn => AccountStage.SigningIn,
            AccountState.SignedIn => AccountStage.SignedIn,
            AccountState.Offline => AccountStage.Offline,
            _ => AccountStage.SignedOut,
        };
        var title = string.IsNullOrWhiteSpace(status.Name) ? status.Email : status.Name;
        var devices = status.Problem is EntitlementProblem.DeviceLimitReached limit
            ? AccountDevices.Ordered(limit.Devices)
            : [];
        return new AccountPanel(
            stage,
            title,
            status.Email,
            status.Features.Contains(ProFeature, StringComparer.Ordinal),
            NoticeOf(status),
            devices);
    }

    private static AccountNotice? NoticeOf(AccountStatus status) => status switch
    {
        { State: not AccountState.SignedIn } => null,
        { Problem: EntitlementProblem.Expired } => new AccountNotice(AccountNoticeKind.Expired),
        { Problem: EntitlementProblem.RefreshFailed failed } => new AccountNotice(AccountNoticeKind.RefreshFailed, failed.Code),
        { Problem: EntitlementProblem.DeviceLimitReached } => new AccountNotice(AccountNoticeKind.DeviceLimitReached),
        { Remembered: false } => new AccountNotice(AccountNoticeKind.NotRemembered),
        _ => null,
    };
}

public enum DeviceRemoval
{
    Removed,

    // The device went, but the refresh the core runs after a removal failed, which the error says.
    RemovedNotRefreshed,
    NotRemoved,
}

public static class AccountDevices
{
    // A removal that threw may still have removed the device, so the list read after it decides.
    public static DeviceRemoval Removal(bool succeeded, IReadOnlyList<AccountDevice>? listedAfter, string deviceId)
    {
        ArgumentNullException.ThrowIfNull(deviceId);
        if (succeeded)
        {
            return DeviceRemoval.Removed;
        }

        return listedAfter is not null && listedAfter.All(device => device.Id != deviceId)
            ? DeviceRemoval.RemovedNotRefreshed
            : DeviceRemoval.NotRemoved;
    }

    // The device-limit dialog stays open while the license is still past its limit.
    public static bool PastLimit(AccountStatus status)
    {
        ArgumentNullException.ThrowIfNull(status);
        return status.Problem is EntitlementProblem.DeviceLimitReached;
    }

    // This machine first, then the most recently seen.
    public static IReadOnlyList<AccountDevice> Ordered(IEnumerable<AccountDevice> devices)
    {
        ArgumentNullException.ThrowIfNull(devices);
        return [.. devices.OrderByDescending(device => device.IsThisMachine).ThenByDescending(device => device.LastSeenAt)];
    }

    // The server refuses to remove a device while its offline file is good, and this machine signs out instead.
    public static bool CanRemove(AccountDevice device, DateTimeOffset now)
    {
        ArgumentNullException.ThrowIfNull(device);
        return !device.IsThisMachine && (device.OfflineUntil is not { } until || until <= now);
    }
}
