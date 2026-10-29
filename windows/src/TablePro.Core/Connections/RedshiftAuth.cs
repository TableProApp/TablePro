namespace TablePro.Core.Connections;

/// <summary>Whether a Redshift endpoint is a provisioned cluster or a Serverless workgroup, which call different APIs.</summary>
public enum RedshiftEndpointKind
{
    Cluster,
    Serverless,
}

/// <summary>The cluster or workgroup a Redshift endpoint names, and the region it runs in.</summary>
public sealed record RedshiftEndpoint(RedshiftEndpointKind Kind, string Identifier, string Region);

/// <summary>
/// Reads which Redshift cluster or Serverless workgroup a profile reaches, the way the macOS app does: only a host name
/// AWS issued, under the region's own DNS suffix, counts, since anything else may be someone else's server and the
/// temporary password goes to the host the driver dials.
/// </summary>
public static class RedshiftAuth
{
    /// <summary>The longest Redshift accepts for <c>GetClusterCredentials</c>; the password is refreshed well inside it.</summary>
    public const int CredentialLifetimeSeconds = 900;

    // The DNS suffix of each AWS partition, by region prefix; every other region is in the standard partition.
    private static readonly (string Prefix, string DnsSuffix)[] Partitions =
    [
        ("cn-", "amazonaws.com.cn"),
        ("us-gov-", "amazonaws.com"),
        ("us-isob-", "sc2s.sgov.gov"),
        ("us-isof-", "csp.hci.ic.gov"),
        ("us-iso-", "c2s.ic.gov"),
        ("eu-isoe-", "cloud.adc-e.uk"),
        ("eusc-", "amazonaws.eu"),
    ];

    /// <summary>The DNS suffix of the partition a region belongs to.</summary>
    public static string DnsSuffix(string region)
    {
        ArgumentNullException.ThrowIfNull(region);
        var normalized = region.Trim().ToLowerInvariant();
        foreach (var (prefix, suffix) in Partitions)
        {
            if (normalized.StartsWith(prefix, StringComparison.Ordinal))
            {
                return suffix;
            }
        }

        return "amazonaws.com";
    }

    /// <summary>
    /// The cluster in <c>my-cluster.abc123.us-east-1.redshift.amazonaws.com</c> or the workgroup in
    /// <c>wg.123456789012.us-east-1.redshift-serverless.amazonaws.com</c>, or null for any other host.
    /// </summary>
    public static RedshiftEndpoint? ParseHost(string? host)
    {
        if (string.IsNullOrWhiteSpace(host))
        {
            return null;
        }

        var labels = host.Trim().TrimEnd('.').ToLowerInvariant().Split('.');
        if (labels.Length <= 4 || labels[0].Length == 0 || labels[1].Length == 0 || labels[2].Length == 0)
        {
            return null;
        }

        var region = labels[2];
        if (!string.Equals(string.Join('.', labels[4..]), DnsSuffix(region), StringComparison.Ordinal))
        {
            return null;
        }

        return labels[3] switch
        {
            "redshift" => new RedshiftEndpoint(RedshiftEndpointKind.Cluster, labels[0], region),
            "redshift-serverless" => new RedshiftEndpoint(RedshiftEndpointKind.Serverless, labels[0], region),
            _ => null,
        };
    }

    /// <summary>
    /// The endpoint to ask credentials for: the profile's Redshift endpoint when it dials a local port forward or that
    /// same endpoint, otherwise its own host.
    /// </summary>
    /// <exception cref="InvalidOperationException">Neither names a Redshift cluster or workgroup.</exception>
    public static RedshiftEndpoint ResolveEndpoint(ConnectionProfile profile)
    {
        ArgumentNullException.ThrowIfNull(profile);
        var host = profile.Host.Trim();
        if (profile.Auth?.AwsRedshiftEndpoint is { } configured && !string.IsNullOrWhiteSpace(configured))
        {
            var overrideHost = HostName(configured);
            var endpoint = ParseHost(overrideHost)
                ?? throw new InvalidOperationException($"\"{configured.Trim()}\" is not a Redshift cluster or Serverless workgroup endpoint.");

            // The temporary password goes to the host the driver dials, so it must be a forward or that endpoint itself.
            if (!IsLoopback(host) && !string.Equals(overrideHost, host, StringComparison.OrdinalIgnoreCase))
            {
                throw new InvalidOperationException($"The Redshift endpoint applies only when the host is a local port forward or that same endpoint, and \"{host}\" is neither.");
            }

            return endpoint;
        }

        return ParseHost(host)
            ?? throw new InvalidOperationException($"TablePro cannot tell which Redshift cluster or workgroup \"{host}\" is. Set the host to the endpoint AWS issued, such as my-cluster.abc123.us-east-1.redshift.amazonaws.com, or enter that endpoint as the Redshift endpoint when you connect through a port forward.");
    }

    /// <summary>The user to ask Redshift for: the one recorded when the session's user was issued, else the profile's.</summary>
    public static string? RequestedUser(ConnectionProfile profile)
    {
        ArgumentNullException.ThrowIfNull(profile);
        var user = profile.Auth?.RedshiftIssued is { } issued ? issued.RequestedUser : profile.Username;
        return string.IsNullOrWhiteSpace(user) ? null : user.Trim();
    }

    private static bool IsLoopback(string host)
    {
        var normalized = host.Trim().ToLowerInvariant();
        return normalized is "localhost" or "localhost.localdomain" or "::1" or "[::1]" or "0.0.0.0" || normalized.StartsWith("127.", StringComparison.Ordinal);
    }

    /// <summary>The host in a value someone pasted with a scheme, a port or a path.</summary>
    private static string HostName(string value)
    {
        var text = value.Trim();
        if (text.IndexOf("://", StringComparison.Ordinal) is var scheme and >= 0)
        {
            text = text[(scheme + 3)..];
        }

        if (text.IndexOf('/', StringComparison.Ordinal) is var slash and >= 0)
        {
            text = text[..slash];
        }

        if (text.LastIndexOf(':') is var colon and >= 0)
        {
            text = text[..colon];
        }

        return text;
    }
}
