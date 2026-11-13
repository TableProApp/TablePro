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

// Every expiry is listed; one the plan does not allow is disabled, and Never on Free carries a Pro tag.
public sealed record ExpiryChoice(ShareExpiry Expiry, bool Enabled, bool ProTag);

// The footer line: "Free · 3 of 5 links · first 1,000 rows" or "Pro · 12 links".
public sealed record ShareFooter(bool Pro, long Live, long Limit, long MaxRows);

// The at-cap line: "You have 7 live links. Free allows 5." and, on Free, "Pro allows up to 1,000."
public sealed record ShareCap(bool Pro, long Live, long Limit);

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

    private SharePlan(ShareLimits limits, ShareKind kind, long totalRows, bool hasSql)
    {
        Limits = limits;
        Kind = kind;
        HasSql = hasSql;
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

    public bool AtCap => Limits.Live >= Limits.LiveLimit;

    public ShareStage Stage => Limits switch
    {
        { EmailVerified: false } => ShareStage.EmailUnverified,
        { SharingDisabled: true } => ShareStage.SharingDisabled,
        _ when AtCap => ShareStage.AtCap,
        _ => ShareStage.Form,
    };

    public ShareFooter Footer => new(IsPro, Limits.Live, Limits.LiveLimit, Limits.MaxRows);

    // Live, not the limit: after a downgrade an account can hold more live links than its plan allows.
    public ShareCap Cap => new(IsPro, Limits.Live, Limits.LiveLimit);

    public static SharePlan For(ShareLimits limits, ShareKind kind, long totalRows = 0, bool hasSql = true)
    {
        ArgumentNullException.ThrowIfNull(limits);
        return new SharePlan(limits, kind, totalRows, hasSql);
    }

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
        };
    }

    // The links a revoke would free a slot of, oldest first. Team links never count against the personal limit.
    public static IReadOnlyList<SharedLink> LiveOldestFirst(IEnumerable<SharedLink> links)
    {
        ArgumentNullException.ThrowIfNull(links);
        return [.. links
            .Where(link => link.IsLive && link.Scope == "account")
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
        "account.validation_failed" => "ShareErrorInvalid",
        _ => Failed,
    };

    // A refusal the limits explain: reading them again shows the sheet the server's view.
    public static bool ReloadsLimits(string code) =>
        code is "account.share_limit_reached" or "account.email_unverified" or "account.sharing_disabled";
}
