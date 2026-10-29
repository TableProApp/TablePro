using System.Net.Http.Headers;
using System.Text;
using TablePro.Core.Connections;
using TablePro.Core.Drivers;
using TablePro.Drivers.Elasticsearch.Localization;
using TablePro.Drivers.Http;

namespace TablePro.Drivers.Elasticsearch;

/// <summary>Elasticsearch and OpenSearch over the REST API.</summary>
public sealed class ElasticsearchDriver : IDatabaseDriver
{
    public IReadOnlyList<DatabaseEngine> Engines { get; } = [DatabaseEngine.Elasticsearch];

    public async Task<IDatabaseSession> ConnectAsync(ConnectionRequest request, CancellationToken cancellationToken)
    {
        var handler = HttpEndpoint.CreateHandler(request.Profile.SslMode, request.Profile.ConnectTimeoutSeconds);
        return await ElasticsearchSession.ConnectAsync(request, handler, cancellationToken);
    }
}

/// <summary>Reads the connection form: where to send requests and how to sign them.</summary>
internal static class ElasticsearchSettings
{
    public const string AuthOption = "auth";
    public const string CloudIdOption = "cloudId";
    public const string ShowHiddenOption = "showHidden";

    /// <summary>
    /// A cloud id names the deployment, so it replaces the host, unless an SSH tunnel has already moved the request to
    /// its local end.
    /// </summary>
    public static Uri BaseUri(ConnectionRequest request)
    {
        var profile = request.Profile;
        if (profile.AdditionalOptions.TryGetValue(CloudIdOption, out var cloudId) && !string.IsNullOrWhiteSpace(cloudId)
            && string.Equals(request.Host, profile.Host, StringComparison.OrdinalIgnoreCase))
        {
            return CloudUri(cloudId);
        }

        return HttpEndpoint.BaseUri(request.Host, request.Port, profile.SslMode != SslMode.Disabled);
    }

    /// <summary>
    /// An Elastic Cloud id is <c>name:base64(host$es-uuid$kibana-uuid)</c>; the cluster answers at
    /// <c>https://es-uuid.host</c>, on 443 unless the host carries a port.
    /// </summary>
    public static Uri CloudUri(string cloudId)
    {
        var encoded = cloudId.Trim();
        var colon = encoded.IndexOf(':', StringComparison.Ordinal);
        if (colon >= 0)
        {
            encoded = encoded[(colon + 1)..];
        }

        string decoded;
        try
        {
            decoded = Encoding.UTF8.GetString(Convert.FromBase64String(encoded.PadRight(encoded.Length + ((4 - (encoded.Length % 4)) % 4), '=')));
        }
        catch (FormatException ex)
        {
            throw new ArgumentException(ElasticsearchStrings.Get("Elasticsearch/CloudIdInvalid"), nameof(cloudId), ex);
        }

        var parts = decoded.Split('$');
        if (parts.Length < 2 || parts[0].Length == 0 || parts[1].Length == 0)
        {
            throw new ArgumentException(ElasticsearchStrings.Get("Elasticsearch/CloudIdInvalid"), nameof(cloudId));
        }

        var host = parts[0];
        var port = 443;
        var portSeparator = host.LastIndexOf(':');
        if (portSeparator > 0 && int.TryParse(host.AsSpan(portSeparator + 1), out var explicitPort))
        {
            port = explicitPort;
            host = host[..portSeparator];
        }

        return new UriBuilder(Uri.UriSchemeHttps, $"{parts[1]}.{host}", port).Uri;
    }

    /// <summary>An API key goes in the password field when the auth option says so; otherwise a username means basic auth.</summary>
    public static AuthenticationHeaderValue? Authorization(ConnectionRequest request)
    {
        var profile = request.Profile;
        if (profile.AdditionalOptions.TryGetValue(AuthOption, out var auth) && string.Equals(auth, "apikey", StringComparison.OrdinalIgnoreCase))
        {
            return string.IsNullOrEmpty(request.Password) ? null : new AuthenticationHeaderValue("ApiKey", request.Password);
        }

        if (string.IsNullOrEmpty(profile.Username))
        {
            return null;
        }

        var credentials = Convert.ToBase64String(Encoding.UTF8.GetBytes($"{profile.Username}:{request.Password}"));
        return new AuthenticationHeaderValue("Basic", credentials);
    }

    public static bool ShowHidden(ConnectionProfile profile) =>
        profile.AdditionalOptions.TryGetValue(ShowHiddenOption, out var value) && string.Equals(value, "true", StringComparison.OrdinalIgnoreCase);
}
