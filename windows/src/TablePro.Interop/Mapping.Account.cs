using Native = TablePro.Interop.Native;

namespace TablePro.Interop;

// The account and share records; times cross as seconds from the Unix epoch.
internal static partial class Mapping
{
    public static Native.AccountConfig Account(AccountConfiguration configuration) => new(
        configuration.AccountUrl,
        configuration.ApiUrl,
        [.. configuration.EntitlementKeys],
        configuration.DeviceName,
        configuration.AppVersion,
        configuration.OsVersion,
        configuration.AccountFile,
        configuration.CallbackFinished,
        configuration.CallbackUnknown,
        configuration.MachineGuid);

    public static AccountStatus Status(Native.AccountStatusInfo status) => new(
        status.State switch
        {
            Native.AccountStateTag.SignedIn => AccountState.SignedIn,
            Native.AccountStateTag.Offline => AccountState.Offline,
            _ => AccountState.SignedOut,
        },
        status.AccountId,
        status.Email,
        status.Name,
        [.. status.Features],
        [.. status.Licenses.Select(License)],
        Time(status.EntitlementExpiresAtSecs),
        status.Problem switch
        {
            Native.EntitlementProblemTag.Expired => EntitlementProblem.Expired.Instance,
            Native.EntitlementProblemTag.RefreshFailed failed => new EntitlementProblem.RefreshFailed(failed.Code),
            Native.EntitlementProblemTag.DeviceLimitReached limit =>
                new EntitlementProblem.DeviceLimitReached([.. limit.Devices.Select(Device)]),
            _ => null,
        },
        status.Remembered);

    public static FeatureAccess Access(Native.FeatureAccessTag access) => access switch
    {
        Native.FeatureAccessTag.Available => FeatureAccess.Available,
        Native.FeatureAccessTag.NotIncluded => FeatureAccess.NotIncluded,
        Native.FeatureAccessTag.Expired => FeatureAccess.Expired,
        Native.FeatureAccessTag.RefreshFailed => FeatureAccess.RefreshFailed,
        Native.FeatureAccessTag.DeviceLimitReached => FeatureAccess.DeviceLimitReached,
        _ => FeatureAccess.SignedOut,
    };

    public static AccountProfile Profile(Native.ProfileInfo profile) => new(
        profile.Id,
        profile.Email,
        profile.Name,
        [.. profile.Licenses.Select(License)],
        [.. profile.Teams.Select(team => new AccountMembership(Team(team.Team), team.Role, team.HasSeat))]);

    public static AccountDevice Device(Native.DeviceInfo device) => new(
        device.Id,
        device.Platform,
        device.Name,
        device.AppVersion,
        device.OsVersion,
        DateTimeOffset.FromUnixTimeSeconds(device.LastSeenAtSecs),
        Time(device.LicensedAtSecs),
        Time(device.OfflineUntilSecs),
        device.IsThisMachine);

    public static ShareLimits Limits(Native.ShareLimitsInfo limits) => new(
        limits.Plan,
        Count(limits.Live),
        Count(limits.LiveLimit),
        Count(limits.MaxRows),
        [.. limits.Expiries.Select(Expiry)],
        limits.DefaultExpiry is { } expiry ? Expiry(expiry) : null,
        limits.Password,
        limits.DisableDownload,
        limits.Team,
        limits.EmailVerified,
        limits.SharingDisabled);

    public static Native.ShareRequestArg Request(ShareRequest request) => new(
        request.Kind == ShareKind.Result ? Native.ShareKindTag.Result : Native.ShareKindTag.Query,
        request.Sql,
        request.Title,
        request.Note,
        request.Dialect,
        request.Expiry is { } expiry ? Expiry(expiry) : null,
        request.HideSql,
        request.AllowDownload,
        request.Password,
        request.TeamId);

    public static Native.ShareExpiryTag Expiry(ShareExpiry expiry) => expiry switch
    {
        ShareExpiry.OneDay => Native.ShareExpiryTag.OneDay,
        ShareExpiry.SevenDays => Native.ShareExpiryTag.SevenDays,
        ShareExpiry.ThirtyDays => Native.ShareExpiryTag.ThirtyDays,
        ShareExpiry.Never => Native.ShareExpiryTag.Never,
        _ => throw new ArgumentOutOfRangeException(nameof(expiry), expiry, null),
    };

    public static SharedLink Link(Native.ShareInfo share) => new(
        share.Id,
        share.Kind,
        share.Scope,
        share.TeamId,
        share.Title,
        share.Note,
        share.Dialect,
        share.Sql,
        share.HasSnapshot,
        share.RowCount is { } rows ? Count(rows) : null,
        share.Truncated,
        share.HideSql,
        share.AllowDownload,
        share.HasPassword,
        share.State,
        share.RemovedReason,
        Count(share.ViewCount),
        DateTimeOffset.FromUnixTimeSeconds(share.CreatedAtSecs),
        DateTimeOffset.FromUnixTimeSeconds(share.UpdatedAtSecs),
        Time(share.ExpiresAtSecs),
        Time(share.RevokedAtSecs),
        Time(share.RemovedAtSecs),
        share.Url);

    public static CreatedShare Created(Native.CreatedShareInfo created) => new(Link(created.Share), created.Url);

    public static SharePage Page(Native.SharePageInfo page) =>
        new([.. page.Shares.Select(Link)], page.NextCursor);

    public static PublicShare Public(Native.SharedLinkInfo shared) => new(
        shared.Kind,
        shared.Title,
        shared.Note,
        shared.Dialect,
        shared.Sql,
        DateTimeOffset.FromUnixTimeSeconds(shared.CreatedAtSecs),
        Time(shared.ExpiresAtSecs),
        shared.AllowDownload,
        shared.RowCount is { } rows ? Count(rows) : null,
        shared.Truncated);

    public static SecretHit Hit(Native.SecretHitInfo hit) => new(
        hit.Kind switch
        {
            Native.SecretHitKindTag.AwsAccessKey => SecretHitKind.AwsAccessKey,
            Native.SecretHitKindTag.PrivateKey => SecretHitKind.PrivateKey,
            Native.SecretHitKindTag.JsonWebToken => SecretHitKind.JsonWebToken,
            Native.SecretHitKindTag.GitHubToken => SecretHitKind.GitHubToken,
            Native.SecretHitKindTag.SlackToken => SecretHitKind.SlackToken,
            Native.SecretHitKindTag.StripeKey => SecretHitKind.StripeKey,
            Native.SecretHitKindTag.GoogleApiKey => SecretHitKind.GoogleApiKey,
            Native.SecretHitKindTag.UrlCredentials => SecretHitKind.UrlCredentials,
            _ => SecretHitKind.AssignedSecret,
        },
        checked((int)hit.Line));

    private static ShareExpiry Expiry(Native.ShareExpiryTag expiry) => expiry switch
    {
        Native.ShareExpiryTag.OneDay => ShareExpiry.OneDay,
        Native.ShareExpiryTag.SevenDays => ShareExpiry.SevenDays,
        Native.ShareExpiryTag.ThirtyDays => ShareExpiry.ThirtyDays,
        _ => ShareExpiry.Never,
    };

    private static AccountLicense License(Native.LicenseInfo license) => new(
        license.Id,
        license.Plan,
        license.Cycle,
        license.Source,
        license.Status,
        Time(license.RenewsAtSecs),
        Time(license.EndsAtSecs),
        license.Team is { } team ? Team(team) : null);

    private static AccountTeam Team(Native.TeamInfo team) => new(team.Id, team.Name);

    private static DateTimeOffset? Time(long? seconds) =>
        seconds is { } at ? DateTimeOffset.FromUnixTimeSeconds(at) : null;
}
