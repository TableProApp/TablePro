using System.Globalization;
using TablePro.Core.Connections;

namespace TablePro.Ssh;

/// <summary>The argument lists and environments for cloud-sql-proxy and cloudflared, kept pure so tests pin them.</summary>
public static class HelperArguments
{
    public const string CloudSqlProxyName = "cloud-sql-proxy";
    public const string CloudflaredName = "cloudflared";

    /// <summary>cloud-sql-proxy reads every flag from a <c>CSQL_PROXY_</c> variable; this one carries the key JSON.</summary>
    public const string CloudSqlJsonCredentialsVariable = "CSQL_PROXY_JSON_CREDENTIALS";

    public const string CloudflareTokenIdVariable = "TUNNEL_SERVICE_TOKEN_ID";
    public const string CloudflareTokenSecretVariable = "TUNNEL_SERVICE_TOKEN_SECRET";

    /// <summary>
    /// <c>cloud-sql-proxy --port N --address 127.0.0.1 [--auto-iam-authn] [--private-ip] instance</c>, the macOS app's
    /// command line. A service account key goes in the child's environment rather than a temporary file, so no copy of
    /// it is left on disk if the app is killed.
    /// </summary>
    public static IReadOnlyList<string> CloudSqlProxy(CloudSqlProxySettings settings, int localPort)
    {
        ArgumentNullException.ThrowIfNull(settings);
        var arguments = new List<string> { "--port", localPort.ToString(CultureInfo.InvariantCulture), "--address", SshArguments.LoopbackAddress };
        if (settings.UseIamAuth)
        {
            arguments.Add("--auto-iam-authn");
        }

        if (settings.UsePrivateIp)
        {
            arguments.Add("--private-ip");
        }

        arguments.Add(settings.InstanceConnectionName.Trim());
        return arguments;
    }

    public static IReadOnlyDictionary<string, string> CloudSqlProxyEnvironment(CloudSqlProxySettings settings, string? serviceAccountKeyJson)
    {
        ArgumentNullException.ThrowIfNull(settings);
        if (settings.AuthMode != CloudSqlAuthMode.ServiceAccountKey)
        {
            return new Dictionary<string, string>();
        }

        if (string.IsNullOrWhiteSpace(serviceAccountKeyJson))
        {
            throw new TunnelException(TunnelFailureKind.InvalidSettings, "A service account key is required. Paste the key's JSON in the connection's Cloud SQL settings.");
        }

        return new Dictionary<string, string> { [CloudSqlJsonCredentialsVariable] = serviceAccountKeyJson.Trim() };
    }

    /// <summary><c>cloudflared access tcp --hostname H --url 127.0.0.1:N</c>; cloudflared opens the listener itself.</summary>
    public static IReadOnlyList<string> Cloudflared(CloudflareTunnelSettings settings, int localPort)
    {
        ArgumentNullException.ThrowIfNull(settings);
        var listen = settings.ExposeToLan ? "0.0.0.0" : SshArguments.LoopbackAddress;
        return ["access", "tcp", "--hostname", settings.AccessHostname.Trim(), "--url", string.Create(CultureInfo.InvariantCulture, $"{listen}:{localPort}")];
    }

    /// <summary>The service token's id and secret, which cloudflared reads from these variables.</summary>
    public static IReadOnlyDictionary<string, string> CloudflaredEnvironment(CloudflareTunnelSettings settings, string? tokenId, string? tokenSecret)
    {
        ArgumentNullException.ThrowIfNull(settings);
        if (settings.AuthMethod != CloudflareAuthMethod.ServiceToken)
        {
            return new Dictionary<string, string>();
        }

        if (string.IsNullOrWhiteSpace(tokenId) || string.IsNullOrWhiteSpace(tokenSecret))
        {
            throw new TunnelException(TunnelFailureKind.InvalidSettings, "Service token ID and secret are required.");
        }

        return new Dictionary<string, string>
        {
            [CloudflareTokenIdVariable] = tokenId.Trim(),
            [CloudflareTokenSecretVariable] = tokenSecret.Trim(),
        };
    }

    /// <summary>The arguments of <c>cloudflared access login</c>, which signs in with the browser and caches the token.</summary>
    public static IReadOnlyList<string> CloudflaredLogin(CloudflareTunnelSettings settings)
    {
        ArgumentNullException.ThrowIfNull(settings);
        return ["access", "login", settings.AccessHostname.Trim()];
    }

    /// <summary>
    /// The sign-in address cloudflared prints when Access needs a browser login, or null. It accepts on its local port
    /// before signing in, so the port alone does not say the tunnel works.
    /// </summary>
    public static Uri? CloudflaredSignInUri(string output)
    {
        ArgumentNullException.ThrowIfNull(output);
        foreach (var line in output.Split('\n'))
        {
            if (!line.Contains("/cdn-cgi/access/", StringComparison.Ordinal) && !line.Contains("browser window should have opened", StringComparison.OrdinalIgnoreCase))
            {
                continue;
            }

            var start = line.IndexOf("https://", StringComparison.Ordinal);
            if (start < 0)
            {
                continue;
            }

            var end = line.IndexOfAny([' ', '\t', '"', '\'', '\r'], start);
            var text = end < 0 ? line[start..] : line[start..end];
            if (Uri.TryCreate(text, UriKind.Absolute, out var uri))
            {
                return uri;
            }
        }

        return null;
    }
}
