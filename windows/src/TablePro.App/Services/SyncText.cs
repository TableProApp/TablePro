using System.Globalization;
using TablePro.App.Model;
using TablePro.Interop;

namespace TablePro.App.Services;

// TablePro Sync's states in words, worded as the macOS app's Sync pane words them.
internal static class SyncText
{
    public static string ProviderSummary(SyncProvider provider) => Strings.Get(provider == SyncProvider.TableProSync
        ? "SyncProviderTableProSyncSummary"
        : "SyncProviderOffSummary");

    public static string Status(SyncStatusKind kind) => Strings.Get("SyncStatus" + kind);

    // Segoe Fluent Icons, as the other Settings cards draw theirs.
    public static string Glyph(SyncStatusKind kind) => kind switch
    {
        SyncStatusKind.UpToDate => "",
        SyncStatusKind.Syncing or SyncStatusKind.Starting => "",
        SyncStatusKind.Waiting => "",
        SyncStatusKind.DownloadingOnly => "",
        SyncStatusKind.NeedsApproval or SyncStatusKind.NeedsRecoveryKey => "",
        SyncStatusKind.Locked => "",
        SyncStatusKind.Off => "",
        _ => "",
    };

    // What the status card says under its title: why, else when this PC last synced.
    public static string Detail(SyncPane pane)
    {
        ArgumentNullException.ThrowIfNull(pane);
        if (pane.Problem is { } code)
        {
            return Code(code);
        }

        return pane.Status switch
        {
            SyncStatusKind.Locked when pane.LockCause is { } cause => LockMessage(cause),
            SyncStatusKind.NeedsApproval => Strings.Get("SyncNeedsApprovalDetail"),
            SyncStatusKind.NeedsRecoveryKey => Strings.Get("SyncNeedsRecoveryKeyDetail"),
            SyncStatusKind.Starting or SyncStatusKind.Syncing => string.Empty,
            _ => pane.LastPass is { } last ? LastSynced(last, DateTimeOffset.Now) : Strings.Get("SyncNeverSynced"),
        };
    }

    // The time alone today, as the history pane shows a run of today.
    public static string LastSynced(DateTimeOffset at, DateTimeOffset now)
    {
        var local = at.ToLocalTime();
        var format = local.Date == now.ToLocalTime().Date ? "t" : "g";
        return Strings.Format("SyncLastSynced", local.ToString(format, CultureInfo.CurrentCulture));
    }

    public static string LockTitle(SyncLockCause cause) => Strings.Get("SyncLockTitle_" + cause);

    public static string LockMessage(SyncLockCause cause) => Strings.Get("SyncLockMessage_" + cause);

    public static string Policy(SyncServerPolicy policy) => Strings.Get("SyncPolicy_" + policy);

    public static string Refusal(SyncRefusal refusal) => Strings.Get("SyncRefusal_" + refusal);

    // What the upload needs before anything goes up.
    public static string KeysStep(UploadKeysStep step) => Strings.Get("SyncUploadKeys_" + step);

    // A code alone, as a status's problem carries it.
    public static string Code(string code) => Strings.Error(new CoreError(code, [code], code, null, null));
}
