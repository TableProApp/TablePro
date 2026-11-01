using System.Globalization;
using System.Security.Cryptography;
using System.Text;
using TablePro.Core.Localization;

namespace TablePro.Core.Connections;

/// <summary>AWS credentials resolved for one signing. The session token is set for temporary credentials.</summary>
public sealed record AwsCredentialSet(string AccessKeyId, string SecretAccessKey, string? SessionToken = null);

/// <summary>
/// An Amazon RDS IAM authentication token: a SigV4 presigned <c>connect</c> request for the <c>rds-db</c> service,
/// sent as the password. Built here rather than with the RDS SDK, the same way the macOS app builds it, since it is a
/// pure function of the credentials, the endpoint and the clock.
/// </summary>
public static class RdsAuthToken
{
    public const int LifetimeSeconds = 900;
    private const string Service = "rds-db";

    /// <param name="credentials">The signing credentials.</param>
    /// <param name="host">The RDS endpoint the database is reached at, never a tunnel's loopback address.</param>
    /// <param name="port">The endpoint's port.</param>
    /// <param name="region">The region the instance runs in.</param>
    /// <param name="user">The database user, which must be granted <c>rds_iam</c> (PostgreSQL) or use the AWS plugin (MySQL).</param>
    /// <param name="now">The signing time; the token is valid for <see cref="LifetimeSeconds"/> after it.</param>
    public static string Generate(AwsCredentialSet credentials, string host, int port, string region, string user, DateTimeOffset now)
    {
        ArgumentNullException.ThrowIfNull(credentials);
        ArgumentException.ThrowIfNullOrWhiteSpace(host);
        ArgumentException.ThrowIfNullOrWhiteSpace(region);
        ArgumentException.ThrowIfNullOrWhiteSpace(user);

        var endpoint = string.Create(CultureInfo.InvariantCulture, $"{host.ToLowerInvariant()}:{port}");
        var parameters = new List<KeyValuePair<string, string>>
        {
            new("Action", "connect"),
            new("DBUser", user),
        };
        var query = AwsSigV4.PresignQuery("GET", endpoint, "/", parameters, credentials, region, Service, now, LifetimeSeconds, AwsSigV4.EmptyPayloadHash);
        return endpoint + "/?" + query;
    }

    /// <summary>The region in an RDS host name such as <c>db.abc123.eu-west-1.rds.amazonaws.com</c>, or null.</summary>
    public static string? RegionFromHost(string? host)
    {
        if (string.IsNullOrWhiteSpace(host))
        {
            return null;
        }

        var labels = host.Trim().TrimEnd('.').ToLowerInvariant().Split('.');
        var rds = Array.IndexOf(labels, "rds");
        return rds >= 2 && rds + 1 < labels.Length && labels[rds + 1] == "amazonaws" ? labels[rds - 1] : null;
    }

    /// <summary>
    /// The host and port the token is signed for: the RDS endpoint override when set, otherwise the profile's own host
    /// and port, which stay the server's even when a tunnel rewrites where the driver dials.
    /// </summary>
    /// <exception cref="FormatException">The override is not <c>host[:port]</c>.</exception>
    public static (string Host, int Port) SigningEndpoint(ConnectionProfile profile)
    {
        ArgumentNullException.ThrowIfNull(profile);
        var endpoint = profile.Auth?.AwsRdsEndpoint?.Trim();
        if (string.IsNullOrEmpty(endpoint))
        {
            return (profile.Host.Trim(), profile.EffectivePort);
        }

        var colon = endpoint.LastIndexOf(':');
        if (colon < 0)
        {
            return (endpoint, profile.EffectivePort);
        }

        if (colon == 0 || !int.TryParse(endpoint.AsSpan(colon + 1), NumberStyles.None, CultureInfo.InvariantCulture, out var port) || !ConnectionTransports.IsValidPort(port))
        {
            throw new FormatException(CoreStrings.Get("SignIn/RdsEndpointFormat"));
        }

        return (endpoint[..colon], port);
    }

    /// <summary>The region to sign for: the profile's, else the one in the RDS host name.</summary>
    /// <exception cref="InvalidOperationException">Neither names a region.</exception>
    public static string SigningRegion(ConnectionProfile profile, string signingHost)
    {
        ArgumentNullException.ThrowIfNull(profile);
        if (profile.Auth?.AwsRegion is { Length: > 0 } region && !string.IsNullOrWhiteSpace(region))
        {
            return region.Trim();
        }

        return RegionFromHost(signingHost)
            ?? throw new InvalidOperationException(CoreStrings.Get("SignIn/RdsRegionRequired"));
    }
}

/// <summary>The parts of AWS Signature Version 4 that presigning a request needs.</summary>
internal static class AwsSigV4
{
    public const string Algorithm = "AWS4-HMAC-SHA256";

    /// <summary>SHA-256 of an empty body, hex encoded.</summary>
    public const string EmptyPayloadHash = "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855";

    /// <summary>The canonical query string of a presigned request, with <c>X-Amz-Signature</c> last.</summary>
    public static string PresignQuery(
        string method,
        string hostHeader,
        string path,
        IEnumerable<KeyValuePair<string, string>> parameters,
        AwsCredentialSet credentials,
        string region,
        string service,
        DateTimeOffset now,
        int expiresSeconds,
        string payloadHash)
    {
        var utc = now.UtcDateTime;
        var date = utc.ToString("yyyyMMdd", CultureInfo.InvariantCulture);
        var amzDate = utc.ToString("yyyyMMdd'T'HHmmss'Z'", CultureInfo.InvariantCulture);
        var scope = $"{date}/{region}/{service}/aws4_request";

        var all = new List<KeyValuePair<string, string>>(parameters)
        {
            new("X-Amz-Algorithm", Algorithm),
            new("X-Amz-Credential", $"{credentials.AccessKeyId}/{scope}"),
            new("X-Amz-Date", amzDate),
            new("X-Amz-Expires", expiresSeconds.ToString(CultureInfo.InvariantCulture)),
            new("X-Amz-SignedHeaders", "host"),
        };
        if (!string.IsNullOrEmpty(credentials.SessionToken))
        {
            all.Add(new("X-Amz-Security-Token", credentials.SessionToken));
        }

        var query = string.Join('&', all
            .Select(p => (Key: Encode(p.Key), Value: Encode(p.Value)))
            .OrderBy(p => p.Key, StringComparer.Ordinal)
            .ThenBy(p => p.Value, StringComparer.Ordinal)
            .Select(p => p.Key + "=" + p.Value));

        var canonicalRequest = $"{method}\n{path}\n{query}\nhost:{hostHeader}\n\nhost\n{payloadHash}";
        var stringToSign = $"{Algorithm}\n{amzDate}\n{scope}\n{Hex(SHA256.HashData(Encoding.UTF8.GetBytes(canonicalRequest)))}";
        var signature = Hex(HMACSHA256.HashData(SigningKey(credentials.SecretAccessKey, date, region, service), Encoding.UTF8.GetBytes(stringToSign)));
        return query + "&X-Amz-Signature=" + signature;
    }

    public static byte[] SigningKey(string secretAccessKey, string date, string region, string service)
    {
        var key = HMACSHA256.HashData(Encoding.UTF8.GetBytes("AWS4" + secretAccessKey), Encoding.UTF8.GetBytes(date));
        key = HMACSHA256.HashData(key, Encoding.UTF8.GetBytes(region));
        key = HMACSHA256.HashData(key, Encoding.UTF8.GetBytes(service));
        return HMACSHA256.HashData(key, "aws4_request"u8);
    }

    public static string Hex(ReadOnlySpan<byte> bytes) => Convert.ToHexStringLower(bytes);

    /// <summary>RFC 3986 percent-encoding: everything but the unreserved characters, as SigV4 requires.</summary>
    private static string Encode(string value) => Uri.EscapeDataString(value);
}
