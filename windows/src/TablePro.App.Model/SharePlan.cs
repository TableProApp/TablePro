using System.Globalization;
using System.Text;
using TablePro.Interop;

namespace TablePro.App.Model;

public enum ShareStage
{
    EmailUnverified,
    SharingDisabled,

    // Every live slot is taken: the live links are listed with Revoke until one frees.
    AtCap,
    Form,
}

// Whether a result can be shared now: its columns and the core's summary of what they send must be read first.
public enum ShareReadiness
{
    Reading,
    Ready,
    NoColumns,
    TooLarge,
}

// Every expiry is listed; one the plan does not allow is disabled, and Never on Free carries a Pro tag.
public sealed record ExpiryChoice(ShareExpiry Expiry, bool Enabled, bool ProTag);

// The footer line: "Free · 3 of 5 links · first 1,000 rows", "Pro · 12 links", or a team's "Data · 4 of 1,000 links".
public sealed record ShareFooter(bool Pro, long Live, long Limit, long MaxRows, string? Team = null)
{
    // "Pro · 1 link" counts its links; the others count against a limit, which stays plural.
    public string ProKey => Live == 1 ? "ShareFooterProOne" : "ShareFooterProMany";
}

// The at-cap line: "You have 7 live links. Free allows 5." and, on Free, "Pro allows up to 1,000."; or a team's.
public sealed record ShareCap(bool Pro, long Live, long Limit, string? Team = null);

// Share as: Personal (no TeamId), then each seated team; one whose public links are off is listed, not offered.
public sealed record ShareOwner(string? TeamId, string? Name, bool Enabled);

// What the sheet's fields hold when Share is pressed.
public sealed record ShareForm(
    string Title,
    string Note,
    ShareExpiry Expiry,
    bool HideSql,
    string Password,
    bool AllowDownload)
{
    // The record's own ToString would print the password into a log line or a debugger's summary.
    private bool PrintMembers(StringBuilder builder)
    {
        builder.Append(
            CultureInfo.InvariantCulture,
            $"Title = {Title}, Expiry = {Expiry}, HideSql = {HideSql}, HasPassword = {Password.Length > 0}, ");
        builder.Append(CultureInfo.InvariantCulture, $"AllowDownload = {AllowDownload}");
        return true;
    }
}

// What one share sheet offers, from the plan's limits (share links PLAN, Client UX).
public sealed class SharePlan
{
    public const string ProPlan = "pro";

    // The preview shows this many rows of the visible columns.
    public const int PreviewRows = 5;

    private static readonly ShareExpiry[] AllExpiries =
        [ShareExpiry.OneDay, ShareExpiry.SevenDays, ShareExpiry.ThirtyDays, ShareExpiry.Never];

    private SharePlan(ShareLimits limits, ShareKind kind, long totalRows, bool hasSql, string? teamId)
    {
        Limits = limits;
        Kind = kind;
        HasSql = hasSql;
        Owners =
        [
            new ShareOwner(null, null, true),
            .. limits.Teams.Select(team => new ShareOwner(team.Id, team.Name, team.PublicLinks)),
        ];
        Team = limits.Teams.FirstOrDefault(team => team.Id == teamId && team.PublicLinks);
        TotalRows = kind == ShareKind.Result ? Math.Max(0, totalRows) : 0;
        IsPro = string.Equals(limits.Plan, ProPlan, StringComparison.Ordinal);
        Expiries = [.. AllExpiries.Select(Choice)];
        DefaultExpiry = Expiries.FirstOrDefault(choice => choice.Enabled && choice.Expiry == limits.DefaultExpiry)?.Expiry
            ?? Expiries.LastOrDefault(choice => choice.Enabled)?.Expiry
            ?? ShareExpiry.ThirtyDays;
    }

    public ShareLimits Limits { get; }

    public ShareKind Kind { get; }

    // A table page carries no statement the app can name, so it shares without one.
    public bool HasSql { get; }

    public bool IsPro { get; }

    public IReadOnlyList<ShareOwner> Owners { get; }

    // The team the link is made for, null for a personal link; a team with public links off is never chosen.
    public ShareTeam? Team { get; }

    public string? TeamId => Team?.Id;

    // A team link counts against the team's own limit, never the creator's.
    public long Live => Team?.Live ?? Limits.Live;

    public long LiveLimit => Team?.LiveLimit ?? Limits.LiveLimit;

    public IReadOnlyList<ExpiryChoice> Expiries { get; }

    public ShareExpiry DefaultExpiry { get; }

    public long TotalRows { get; }

    // The client cuts the rows to the plan's limit before upload; the server derives truncated itself.
    public long SharedRows => Math.Min(TotalRows, Math.Max(0, Limits.MaxRows));

    public bool IsTruncated => Kind == ShareKind.Result && TotalRows > SharedRows;

    public long PreviewRowCount => Math.Min(SharedRows, PreviewRows);

    // A query share always shows its SQL.
    public bool OffersHideSql => Kind == ShareKind.Result && HasSql;

    public bool PasswordAllowed => Limits.Password;

    public bool DownloadChoiceAllowed => Limits.DisableDownload;

    public bool AtCap => Live >= LiveLimit;

    public ShareStage Stage => Limits switch
    {
        { EmailVerified: false } => ShareStage.EmailUnverified,
        { SharingDisabled: true } => ShareStage.SharingDisabled,
        _ when AtCap => ShareStage.AtCap,
        _ => ShareStage.Form,
    };

    public ShareFooter Footer => new(IsPro, Live, LiveLimit, Limits.MaxRows, Team?.Name);

    // Live, not the limit: after a downgrade an account can hold more live links than its plan allows.
    public ShareCap Cap => new(IsPro, Live, LiveLimit, Team?.Name);

    public static SharePlan For(
        ShareLimits limits, ShareKind kind, long totalRows = 0, bool hasSql = true, string? teamId = null)
    {
        ArgumentNullException.ThrowIfNull(limits);
        return new SharePlan(limits, kind, totalRows, hasSql, teamId);
    }

    // A summary read for older choices is never passed here: the sheet drops it as stale, so Share waits.
    public ShareReadiness Readiness(ShareColumns? columns, ShareSummary? summary) => Kind switch
    {
        ShareKind.Query => ShareReadiness.Ready,
        _ when columns is null => ShareReadiness.Reading,
        _ when columns.RemovesEveryColumn => ShareReadiness.NoColumns,
        _ when summary is null => ShareReadiness.Reading,
        _ when summary.Refused is ShareRefusal.NoColumns => ShareReadiness.NoColumns,
        _ when summary.Refused is not null => ShareReadiness.TooLarge,
        _ => ShareReadiness.Ready,
    };

    // The body budget can cut a share below the plan's rows, so the row note follows what the core says it sends.
    public bool CutsRows(ShareSummary summary)
    {
        ArgumentNullException.ThrowIfNull(summary);
        return Kind == ShareKind.Result && summary.Refused is null && summary.RowsSent < TotalRows;
    }

    public static int PreviewRowsOf(ShareSummary summary)
    {
        ArgumentNullException.ThrowIfNull(summary);
        return (int)Math.Clamp(summary.RowsSent, 0, PreviewRows);
    }

    // The server takes the first MaxColumns visible columns of a result, on every plan.
    public bool CutsColumns(int visibleColumns) =>
        Kind == ShareKind.Result && Limits.MaxColumns > 0 && visibleColumns > Limits.MaxColumns;

    public int SharedColumns(int visibleColumns) =>
        CutsColumns(visibleColumns) ? (int)Limits.MaxColumns : Math.Max(0, visibleColumns);

    // Free never sends an option the server would refuse with pro_required.
    public ShareRequest Request(ShareForm form, string sql, string? dialect)
    {
        ArgumentNullException.ThrowIfNull(form);
        ArgumentNullException.ThrowIfNull(sql);
        var allowed = Expiries.Any(choice => choice.Enabled && choice.Expiry == form.Expiry);
        return new ShareRequest(Kind, sql)
        {
            Title = Trimmed(form.Title),
            Note = Trimmed(form.Note),
            Dialect = string.IsNullOrWhiteSpace(dialect) ? null : dialect,
            Expiry = allowed ? form.Expiry : DefaultExpiry,
            HideSql = OffersHideSql && form.HideSql,
            Password = PasswordAllowed && form.Password.Length > 0 ? form.Password : null,
            AllowDownload = DownloadChoiceAllowed && !form.AllowDownload ? false : null,
            TeamId = TeamId,
        };
    }

    // The links a revoke would free a slot of, oldest first: the personal ones, or the chosen team's.
    public static IReadOnlyList<SharedLink> LiveOldestFirst(IEnumerable<SharedLink> links, string? teamId = null)
    {
        ArgumentNullException.ThrowIfNull(links);
        return [.. links
            .Where(link => link.IsLive && (teamId is null ? link.Scope == "account" : link.TeamId == teamId))
            .DistinctBy(link => link.Id)
            .OrderBy(link => link.CreatedAt)];
    }

    private ExpiryChoice Choice(ShareExpiry expiry)
    {
        var enabled = Limits.Expiries.Contains(expiry);
        return new ExpiryChoice(expiry, enabled, !enabled && !IsPro && expiry == ShareExpiry.Never);
    }

    private static string? Trimmed(string text) => string.IsNullOrWhiteSpace(text) ? null : text.Trim();
}

// The share sheet's own sentence per problem code (PLAN, Wording); anything else is the general one.
public static class ShareErrors
{
    public const string Failed = "ShareErrorFailed";

    public static string KeyFor(string code) => code switch
    {
        "account.signed_out" => "ShareErrorSignedOut",
        "account.email_unverified" => "ShareErrorEmailUnverified",
        "account.pro_required" => "ShareErrorProRequired",
        "account.sharing_disabled" => "ShareErrorSharingDisabled",
        "account.team_sharing_disabled" => "ShareErrorTeamSharingDisabled",
        "account.snapshot_too_large" => "ShareErrorTooLarge",
        "account.rate_limited" => "ShareErrorRateLimited",
        "account.unreachable" => "ShareErrorOffline",
        "ffi.share_no_columns" => "ShareNoColumns",
        _ => Failed,
    };

    // A refusal the limits explain: reading them again shows the sheet the server's view.
    public static bool ReloadsLimits(string code) =>
        code is "account.share_limit_reached" or "account.email_unverified" or "account.sharing_disabled";
}
