namespace TablePro.Core.Connections;

/// <summary>
/// An Amazon ElastiCache IAM authentication token: a SigV4 presigned <c>connect</c> request for the
/// <c>elasticache</c> service, addressed to the cache by name, which Redis takes as the password of an IAM-enabled
/// user. Built the way the macOS app builds it, as a pure function of the credentials, the cache and the clock.
/// </summary>
public static class ElastiCacheAuthToken
{
    public const int LifetimeSeconds = 900;
    private const string Service = "elasticache";

    /// <param name="credentials">The signing credentials.</param>
    /// <param name="cacheName">The replication group ID or serverless cache name, which the token is signed for as its host.</param>
    /// <param name="region">The region the cache runs in.</param>
    /// <param name="userId">The ElastiCache user, whose ID and name must match for IAM sign-in.</param>
    /// <param name="now">The signing time; the token is valid for <see cref="LifetimeSeconds"/> after it.</param>
    public static string Generate(AwsCredentialSet credentials, string cacheName, string region, string userId, DateTimeOffset now)
    {
        ArgumentNullException.ThrowIfNull(credentials);
        ArgumentException.ThrowIfNullOrWhiteSpace(cacheName);
        ArgumentException.ThrowIfNullOrWhiteSpace(region);
        ArgumentException.ThrowIfNullOrWhiteSpace(userId);

        var host = cacheName.Trim();
        var parameters = new List<KeyValuePair<string, string>>
        {
            new("Action", "connect"),
            new("User", userId),
        };
        var query = AwsSigV4.PresignQuery("GET", host, "/", parameters, credentials, region, Service, now, LifetimeSeconds, AwsSigV4.EmptyPayloadHash);
        return host + "/?" + query;
    }

    /// <summary>The region to sign for: the profile's, else the one the AWS profile names.</summary>
    /// <exception cref="InvalidOperationException">Neither names a region; an ElastiCache endpoint does not spell its region out.</exception>
    public static string SigningRegion(ConnectionProfile profile, string? profileRegion)
    {
        ArgumentNullException.ThrowIfNull(profile);
        if (profile.Auth?.AwsRegion is { } region && !string.IsNullOrWhiteSpace(region))
        {
            return region.Trim();
        }

        return string.IsNullOrWhiteSpace(profileRegion)
            ? throw new InvalidOperationException("Enter the AWS region the ElastiCache cache runs in.")
            : profileRegion.Trim();
    }

    /// <summary>The cache the token is signed for.</summary>
    /// <exception cref="InvalidOperationException">The profile names no cache.</exception>
    public static string CacheName(ConnectionProfile profile)
    {
        ArgumentNullException.ThrowIfNull(profile);
        return profile.Auth?.AwsElastiCacheName is { } name && !string.IsNullOrWhiteSpace(name)
            ? name.Trim()
            : throw new InvalidOperationException("Enter the ElastiCache cache name (replication group ID) to use IAM authentication.");
    }
}
