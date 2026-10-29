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
    // The macOS app's connection fields, so a connection written there opens the same way here.
    public const string ModeOption = "libsqlMode";
    public const string FilePathOption = "libsqlFilePath";

    private static readonly string[] UrlKeys = ["databaseUrl", "url"];

    /// <summary>The options only this driver reads, which the SQLite provider would refuse as unknown keywords.</summary>
    public static readonly IReadOnlySet<string> OwnOptions = new HashSet<string>(StringComparer.OrdinalIgnoreCase) { ModeOption, FilePathOption, "databaseUrl", "url" };

    /// <summary>
    /// The local database file the connection opens, or null for a remote server. A <c>file:</c> URL in the URL
    /// field names one, as libSQL's own clients spell a local database, and so does the macOS app's local mode.
    /// </summary>
    public static string? LocalFile(ConnectionProfile profile)
    {
        var options = profile.AdditionalOptions;
        if (options.TryGetValue(ModeOption, out var mode) && string.Equals(mode?.Trim(), "local", StringComparison.OrdinalIgnoreCase))
        {
            var path = options.TryGetValue(FilePathOption, out var file) && !string.IsNullOrWhiteSpace(file) ? file : profile.FilePath;
            return string.IsNullOrWhiteSpace(path)
                ? throw new LibSqlException("A local libSQL connection needs a database file.")
                : path.Trim();
        }

        var url = UrlKeys.Select(k => options.TryGetValue(k, out var v) ? v : null).FirstOrDefault(v => !string.IsNullOrWhiteSpace(v)) ?? profile.Host;
        return FilePathFromUrl(url);
    }

    /// <summary>
    /// The path in a <c>file:</c> URL: <c>file:C:\data\app.db</c>, <c>file:local.db</c> or <c>file:///C:/data/app.db</c>.
    /// </summary>
    public static string? FilePathFromUrl(string? url)
    {
        var text = url?.Trim();
        if (text is null || !text.StartsWith("file:", StringComparison.OrdinalIgnoreCase))
        {
            return null;
        }

        if (text.StartsWith("file://", StringComparison.OrdinalIgnoreCase) && Uri.TryCreate(text, UriKind.Absolute, out var uri) && uri.IsFile)
        {
            return uri.LocalPath;
        }

        var path = text["file:".Length..];
        return path.Length == 0 ? throw new LibSqlException("The file: URL names no database file.") : path;
    }

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
