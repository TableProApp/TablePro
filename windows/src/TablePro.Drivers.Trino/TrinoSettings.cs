using System.Globalization;
using System.Net.Http.Headers;
using System.Net.Security;
using System.Text;
using TablePro.Core.Connections;
using TablePro.Core.Drivers;

namespace TablePro.Drivers.Trino;

/// <summary>
/// Where the coordinator is and who asks. Read from the connection form: Host (a name or a full URL), Port, Username,
/// Password, Database as the catalog, SSL mode, and the AdditionalOptions <c>catalog</c>, <c>schema</c>,
/// <c>timeZone</c>, <c>accessToken</c> and <c>source</c>.
/// </summary>
public sealed record TrinoSettings(
    Uri BaseUri,
    string User,
    string? Password,
    string? AccessToken,
    string? Catalog,
    string? Schema,
    string? TimeZone,
    string Source,
    SslMode SslMode,
    TimeSpan RequestTimeout)
{
    public const string CatalogOption = "catalog";
    public const string SchemaOption = "schema";
    public const string TimeZoneOption = "timeZone";
    public const string AccessTokenOption = "accessToken";
    public const string SourceOption = "source";

    public bool UsesTls => BaseUri.Scheme == Uri.UriSchemeHttps;

    public static TrinoSettings From(ConnectionRequest request)
    {
        ArgumentNullException.ThrowIfNull(request);
        var profile = request.Profile;
        var options = profile.AdditionalOptions;
        var host = string.IsNullOrWhiteSpace(request.Host) ? "localhost" : request.Host.Trim();

        Uri baseUri;
        if (host.Contains("://", StringComparison.Ordinal))
        {
            // A full URL keeps its own scheme and port; a tunnel never rewrites one because the form cannot tunnel a URL.
            var parsed = new Uri(host, UriKind.Absolute);
            baseUri = new UriBuilder(parsed.Scheme, parsed.Host, parsed.IsDefaultPort ? -1 : parsed.Port).Uri;
        }
        else
        {
            var port = request.Port > 0 ? request.Port : profile.EffectivePort;
            var tls = profile.SslMode switch
            {
                SslMode.Disabled => false,
                SslMode.Required or SslMode.VerifyCa or SslMode.VerifyIdentity => true,

                // The default mode follows the port, since a coordinator on 8080 almost always speaks plain HTTP.
                _ => port is 443 or 8443,
            };
            baseUri = new UriBuilder(tls ? Uri.UriSchemeHttps : Uri.UriSchemeHttp, host, port).Uri;
        }

        return new TrinoSettings(
            baseUri,
            string.IsNullOrWhiteSpace(profile.Username) ? profile.Descriptor.DefaultUser : profile.Username.Trim(),
            string.IsNullOrEmpty(request.Password) ? null : request.Password,
            Option(options, AccessTokenOption),
            Option(options, CatalogOption) ?? (string.IsNullOrWhiteSpace(request.Database) ? null : request.Database.Trim()),
            Option(options, SchemaOption),
            Option(options, TimeZoneOption),
            Option(options, SourceOption) ?? "TablePro",
            profile.SslMode,
            TimeSpan.FromSeconds(Math.Max(profile.ConnectTimeoutSeconds, 30)));
    }

    /// <summary>The Authorization header, or null for an unauthenticated coordinator.</summary>
    public AuthenticationHeaderValue? Authorization =>
        AccessToken is not null
            ? new AuthenticationHeaderValue("Bearer", AccessToken)
            : Password is not null
                ? new AuthenticationHeaderValue("Basic", Convert.ToBase64String(Encoding.UTF8.GetBytes(string.Concat(User, ":", Password))))
                : null;

    /// <summary>Trino refuses credentials over plain HTTP; failing here says why instead of an opaque 401.</summary>
    public void Validate()
    {
        if (!UsesTls && (Password is not null || AccessToken is not null))
        {
            throw new InvalidOperationException(
                string.Create(CultureInfo.InvariantCulture, $"Trino accepts a password or token only over HTTPS. Set the SSL mode to Required or use an https:// URL for {BaseUri.Host}."));
        }
    }

    internal SocketsHttpHandler CreateHandler()
    {
        var handler = new SocketsHttpHandler
        {
            AutomaticDecompression = System.Net.DecompressionMethods.All,
            PooledConnectionLifetime = TimeSpan.FromMinutes(5),
            ConnectTimeout = RequestTimeout,
        };

        // Required encrypts without checking who answers, as libpq's sslmode=require does; VerifyCa skips only the name.
        if (UsesTls && SslMode is SslMode.Required or SslMode.VerifyCa)
        {
            var allowNameMismatch = SslMode == SslMode.VerifyCa;
            var allowAny = SslMode == SslMode.Required;
            handler.SslOptions.RemoteCertificateValidationCallback = (_, _, _, errors) =>
                errors == SslPolicyErrors.None || allowAny || (allowNameMismatch && errors == SslPolicyErrors.RemoteCertificateNameMismatch);
        }

        return handler;
    }

    // The generated ToString would print the password and token into any log that formats the settings.
    public override string ToString() => string.Concat(User, "@", BaseUri.ToString());

    private static string? Option(IReadOnlyDictionary<string, string> options, string key) =>
        options.TryGetValue(key, out var value) && !string.IsNullOrWhiteSpace(value) ? value.Trim() : null;
}
