using Native = TablePro.Interop.Native;

namespace TablePro.Interop;

public enum ShareKind
{
    Query,
    Result,
}

// The server counts the expiry from its own clock.
public enum ShareExpiry
{
    OneDay,
    SevenDays,
    ThirtyDays,
    Never,
}

// What the plan allows now (core ADR 0026). Plan is the server's code, "free" or "pro".
public sealed record ShareLimits(
    string Plan,
    long Live,
    long LiveLimit,
    long MaxRows,
    IReadOnlyList<ShareExpiry> Expiries,
    ShareExpiry? DefaultExpiry,
    bool Password,
    bool DisableDownload,
    bool Team,
    bool EmailVerified,
    bool SharingDisabled);

// Sql is always stored; a result share's snapshot is built by the core from the set it is given.
public sealed record ShareRequest(ShareKind Kind, string Sql)
{
    public string? Title { get; init; }

    public string? Note { get; init; }

    public string? Dialect { get; init; }

    // Null takes the plan's default.
    public ShareExpiry? Expiry { get; init; }

    // Only for a result.
    public bool HideSql { get; init; }

    // Null leaves downloads on.
    public bool? AllowDownload { get; init; }

    public string? Password { get; init; }

    public string? TeamId { get; init; }
}

// A link as its owner sees it. Kind, Scope and State stay the server's codes; Sql only when read on its own.
public sealed record SharedLink(
    string Id,
    string Kind,
    string Scope,
    string? TeamId,
    string Title,
    string Note,
    string Dialect,
    string? Sql,
    bool HasSnapshot,
    long? RowCount,
    bool? Truncated,
    bool HideSql,
    bool AllowDownload,
    bool HasPassword,
    string State,
    string? RemovedReason,
    long ViewCount,
    DateTimeOffset CreatedAt,
    DateTimeOffset UpdatedAt,
    DateTimeOffset? ExpiresAt,
    DateTimeOffset? RevokedAt,
    DateTimeOffset? RemovedAt,
    string? Url)
{
    public bool IsLive => State == "live";
}

public sealed record CreatedShare(SharedLink Share, string Url);

// NextCursor is null on the last page.
public sealed record SharePage(IReadOnlyList<SharedLink> Shares, string? NextCursor);

// A link as anyone with it reads it. Sql is null when the owner hid it, so there is nothing to open.
public sealed record PublicShare(
    string Kind,
    string Title,
    string Note,
    string Dialect,
    string? Sql,
    DateTimeOffset CreatedAt,
    DateTimeOffset? ExpiresAt,
    bool AllowDownload,
    long? RowCount,
    bool? Truncated);

public enum SecretHitKind
{
    AwsAccessKey,
    PrivateKey,
    JsonWebToken,
    GitHubToken,
    SlackToken,
    StripeKey,
    GoogleApiKey,
    UrlCredentials,
    AssignedSecret,
}

// Line counts from 1.
public sealed record SecretHit(SecretHitKind Kind, int Line);

// The core's secret scan and deep link rule, the same for every app. A hit warns and never blocks a share.
public static class ShareLinks
{
    // Each kind once per line, by line.
    public static IReadOnlyList<SecretHit> ScanSql(string sql)
    {
        ArgumentNullException.ThrowIfNull(sql);
        return [.. Native.CoreMethods.ScanSqlForSecrets(sql).Select(Mapping.Hit)];
    }

    // The names of the columns that may hold a secret, in their order, each once.
    public static IReadOnlyList<string> ScanColumns(IEnumerable<string> names)
    {
        ArgumentNullException.ThrowIfNull(names);
        return Native.CoreMethods.ScanColumnsForSecrets([.. names]);
    }

    // The token of tablepro://share?token=<token>, null for any other link or a malformed token.
    public static string? TokenFromLink(string link)
    {
        ArgumentNullException.ThrowIfNull(link);
        return Native.CoreMethods.ShareTokenFromLink(link);
    }
}
