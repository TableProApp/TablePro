using System.Net;
using System.Net.Security;
using ClickHouse.Client.ADO;
using TablePro.Core.Connections;
using TablePro.Core.Drivers;
using CoreSslMode = TablePro.Core.Connections.SslMode;

namespace TablePro.Drivers.ClickHouse;

/// <summary>Builds the ClickHouse.Client connection string and the HTTP handler a session shares.</summary>
internal static class ClickHouseConnectionFactory
{
    public const int HttpPort = 8123;
    public const int HttpsPort = 8443;
    public const string DefaultDatabase = "default";
    public const string DefaultUser = "default";

    // Analytical queries run for minutes; the editor's cancel and CommandTimeout bound them, not the HTTP client.
    private static readonly TimeSpan RequestTimeout = TimeSpan.FromHours(1);

    /// <summary>
    /// HTTP has no opportunistic TLS, so Preferred stays on plain HTTP like Disabled, as the Linux driver does.
    /// </summary>
    public static bool UsesTls(CoreSslMode mode) => mode is CoreSslMode.Required or CoreSslMode.VerifyCa or CoreSslMode.VerifyIdentity;

    /// <summary>
    /// A port the user typed, or the local end of an SSH tunnel, is where to dial. Otherwise the default follows TLS,
    /// because a TLS handshake against the plain HTTP port fails.
    /// </summary>
    public static int ResolvePort(ConnectionRequest request)
    {
        var profile = request.Profile;
        if (profile.Port > 0 || (request.Port > 0 && request.Port != profile.EffectivePort))
        {
            return request.Port > 0 ? request.Port : profile.Port;
        }

        return UsesTls(profile.SslMode) ? HttpsPort : HttpPort;
    }

    public static string Build(ConnectionRequest request, IReadOnlyList<KeyValuePair<string, string>> startupSettings)
    {
        var profile = request.Profile;
        var port = ResolvePort(request);
        var builder = new ClickHouseConnectionStringBuilder
        {
            Host = request.Host,
            Port = checked((ushort)port),
            Protocol = UsesTls(profile.SslMode) ? "https" : "http",
            Database = string.IsNullOrWhiteSpace(request.Database) ? DefaultDatabase : request.Database,
            Username = string.IsNullOrWhiteSpace(profile.Username) ? DefaultUser : profile.Username,
            Password = request.Password ?? string.Empty,
            Compression = true,

            // A session keeps SET and temporary tables between an editor tab's statements. Each connection object
            // gets its own session id, so pooled sidebar reads never collide on the server's one-query-per-session lock.
            UseSession = true,
            Timeout = RequestTimeout,
        };

        // ClickHouse.Client sends every set_ keyword as a setting on each request, which costs no round trip.
        if (profile.IsReadOnly)
        {
            builder["set_readonly"] = "2";
            builder["set_allow_ddl"] = "0";
        }

        foreach (var (name, value) in startupSettings)
        {
            builder["set_" + name] = value;
        }

        foreach (var (key, value) in profile.AdditionalOptions)
        {
            builder[key] = value;
        }

        return builder.ConnectionString;
    }

    /// <summary>One handler per session, so HTTP keep-alive connections are reused across the session's requests.</summary>
    public static SocketsHttpHandler CreateHandler(ConnectionProfile profile)
    {
        var mode = profile.SslMode;
        var handler = new SocketsHttpHandler
        {
            AutomaticDecompression = DecompressionMethods.GZip | DecompressionMethods.Deflate,
            ConnectTimeout = TimeSpan.FromSeconds(Math.Max(profile.ConnectTimeoutSeconds, 1)),

            // Shorter than the server's keep-alive (3 s before 23.11), so a reused connection is never one the server
            // is about to close.
            PooledConnectionIdleTimeout = TimeSpan.FromSeconds(2),
        };

        if (UsesTls(mode) && mode != CoreSslMode.VerifyIdentity)
        {
            handler.SslOptions = new SslClientAuthenticationOptions
            {
                RemoteCertificateValidationCallback = (_, _, _, errors) => AcceptsCertificate(mode, errors),
            };
        }

        return handler;
    }

    /// <summary>
    /// Required encrypts without checking the certificate, as every engine's require does; VerifyCa checks the chain
    /// but not the name; VerifyIdentity checks both.
    /// </summary>
    public static bool AcceptsCertificate(CoreSslMode mode, SslPolicyErrors errors) => mode switch
    {
        CoreSslMode.Required => true,
        CoreSslMode.VerifyCa => (errors & ~SslPolicyErrors.RemoteCertificateNameMismatch) == SslPolicyErrors.None,
        _ => errors == SslPolicyErrors.None,
    };
}
