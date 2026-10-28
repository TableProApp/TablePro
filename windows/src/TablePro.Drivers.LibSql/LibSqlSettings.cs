using System.Globalization;
using TablePro.Core.Connections;
using TablePro.Core.Drivers;

namespace TablePro.Drivers.LibSql;

/// <summary>
/// Where a libSQL connection points. The Host field takes either a bare host name, dialled at the request's host and
/// port, or a full database URL such as <c>libsql://db-org.turso.io</c>, which Turso's dashboard hands out.
/// </summary>
internal static class LibSqlSettings
{
    private static readonly string[] UrlKeys = ["databaseUrl", "url"];

    public static Uri BaseUri(ConnectionRequest request)
    {
        var profile = request.Profile;
        string? url = null;
        foreach (var key in UrlKeys)
        {
            if (profile.AdditionalOptions.TryGetValue(key, out var value) && !string.IsNullOrWhiteSpace(value))
            {
                url = value.Trim();
                break;
            }
        }

        if (url is null && profile.Host.Contains("://", StringComparison.Ordinal))
        {
            url = profile.Host.Trim();
        }

        url = url is null ? FromHostAndPort(profile, request.Host, request.Port) : Normalize(url);
        if (!Uri.TryCreate(url.EndsWith('/') ? url : url + "/", UriKind.Absolute, out var uri) || (uri.Scheme != Uri.UriSchemeHttp && uri.Scheme != Uri.UriSchemeHttps))
        {
            throw new LibSqlException($"'{url}' is not a libSQL database URL. Use libsql://, https:// or http://.");
        }

        return uri;
    }

    /// <summary>libsql:// and wss:// name the same server as https://; Hrana over HTTP is the transport used here.</summary>
    public static string Normalize(string url)
    {
        if (url.StartsWith("libsql://", StringComparison.OrdinalIgnoreCase))
        {
            url = "https://" + url["libsql://".Length..];
        }
        else if (url.StartsWith("wss://", StringComparison.OrdinalIgnoreCase))
        {
            url = "https://" + url["wss://".Length..];
        }
        else if (url.StartsWith("ws://", StringComparison.OrdinalIgnoreCase))
        {
            url = "http://" + url["ws://".Length..];
        }

        return url.TrimEnd('/');
    }

    private static string FromHostAndPort(ConnectionProfile profile, string host, int port)
    {
        var isLocal = host is "localhost" or "127.0.0.1" or "::1" || host.EndsWith(".localhost", StringComparison.OrdinalIgnoreCase);

        // A local sqld serves plain HTTP; Turso and other remote servers only answer over TLS.
        var secure = profile.Engine == DatabaseEngine.Turso || profile.SslMode >= SslMode.Required || (!isLocal && profile.SslMode != SslMode.Disabled);
        var scheme = secure ? "https" : "http";
        var defaultPort = secure ? 443 : 80;
        var hostPart = host.Contains(':', StringComparison.Ordinal) && !host.StartsWith('[') ? $"[{host}]" : host;
        return port <= 0 || port == defaultPort
            ? $"{scheme}://{hostPart}"
            : string.Create(CultureInfo.InvariantCulture, $"{scheme}://{hostPart}:{port}");
    }
}
