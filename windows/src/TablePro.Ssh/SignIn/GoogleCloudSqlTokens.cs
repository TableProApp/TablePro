using System.Collections.Concurrent;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using Google.Apis.Auth.OAuth2;
using Google.Apis.Auth.OAuth2.Responses;
using TablePro.Core.Connections;

namespace TablePro.Ssh.SignIn;

/// <summary>
/// The OAuth access tokens Cloud SQL takes as the password for an IAM database user, from application default
/// credentials or a service account key, as <c>gcloud sql generate-login-token</c> and the Cloud SQL connectors mint
/// them. A credential is kept per distinct key or credentials file, so connections that share one share its cached
/// token, and a new <c>gcloud</c> login or an edited key starts a fresh one.
/// </summary>
internal sealed class GoogleCloudSqlTokens
{
    /// <summary>
    /// What the Cloud SQL connectors ask for. It allows a database sign-in and nothing else, so a token that leaks
    /// cannot call another Google API.
    /// </summary>
    public const string LoginScope = "https://www.googleapis.com/auth/sqlservice.login";

    public const string CredentialsVariable = "GOOGLE_APPLICATION_CREDENTIALS";

    private readonly ConcurrentDictionary<string, Lazy<Task<GoogleCredential>>> _credentials = new(StringComparer.Ordinal);
    private readonly Google.Apis.Http.IHttpClientFactory? _http;

    /// <param name="http">Replaces the HTTP stack token requests use; tests pass a fake one.</param>
    public GoogleCloudSqlTokens(Google.Apis.Http.IHttpClientFactory? http = null)
    {
        _http = http;
    }

    public async Task<string> GetTokenAsync(ConnectionProfile profile, string? secret, CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(profile);
        string key;
        Func<Task<GoogleCredential>> create;
        if (profile.EffectiveSignIn() == SignInMethod.GoogleCloudServiceAccount)
        {
            var json = ServiceAccountJson(secret);
            key = "key:" + Fingerprint(json);
            create = () => Task.FromResult(ServiceAccount(json));
        }
        else
        {
            // gcloud rewrites the file on every login, so its bytes say whether the cached credential is still the user's.
            var path = ApplicationDefaultPath(Environment.GetEnvironmentVariable(CredentialsVariable), Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData));
            var contents = path is not null && File.Exists(path) ? await File.ReadAllTextAsync(path, cancellationToken) : null;
            key = "adc:" + (contents is null ? "environment" : Fingerprint(contents));
            create = ApplicationDefaultAsync;
        }

        try
        {
            // Shared by every caller, so it is never tied to one caller's cancellation.
            var credential = await _credentials.GetOrAdd(key, _ => new Lazy<Task<GoogleCredential>>(create)).Value.WaitAsync(cancellationToken);
            return await ((ITokenAccess)credential).GetAccessTokenForRequestAsync(cancellationToken: cancellationToken);
        }
        catch (Exception ex) when (ex is not OperationCanceledException)
        {
            // A refused key or an expired login must not stay cached; the next connect reads it again.
            _credentials.TryRemove(key, out _);
            throw new InvalidOperationException(Message(ex), ex);
        }
    }

    /// <summary>
    /// Where application default credentials are read from: the file <c>GOOGLE_APPLICATION_CREDENTIALS</c> names, else
    /// the one <c>gcloud auth application-default login</c> writes under <c>%APPDATA%\gcloud</c>.
    /// </summary>
    internal static string? ApplicationDefaultPath(string? variable, string? applicationData)
    {
        if (!string.IsNullOrWhiteSpace(variable))
        {
            return Environment.ExpandEnvironmentVariables(variable.Trim().Trim('"'));
        }

        return string.IsNullOrEmpty(applicationData) ? null : Path.Combine(applicationData, "gcloud", "application_default_credentials.json");
    }

    /// <summary>The key's JSON, from the pasted JSON itself or from the file the value names.</summary>
    /// <exception cref="InvalidOperationException">The value is empty, unreadable, or not a service account key.</exception>
    internal static string ServiceAccountJson(string? value)
    {
        var text = value?.Trim().TrimStart('\xFEFF') ?? string.Empty;
        if (text.Length == 0)
        {
            throw new InvalidOperationException("Enter the service account key: the path of its JSON file, or the JSON itself.");
        }

        if (!text.StartsWith('{'))
        {
            var path = Environment.ExpandEnvironmentVariables(text.Trim('"'));
            if (text.StartsWith("-----BEGIN", StringComparison.Ordinal))
            {
                throw new InvalidOperationException("This is a PEM private key. Use the JSON key file Google Cloud created for the service account.");
            }

            try
            {
                text = File.ReadAllText(path).Trim().TrimStart('\xFEFF');
            }
            catch (Exception ex) when (ex is IOException or UnauthorizedAccessException or ArgumentException or NotSupportedException)
            {
                throw new InvalidOperationException($"The service account key file {path} cannot be read: {ex.Message}", ex);
            }
        }

        string? type;
        try
        {
            using var document = JsonDocument.Parse(text);
            type = document.RootElement.ValueKind == JsonValueKind.Object && document.RootElement.TryGetProperty("type", out var property) ? property.GetString() : null;
        }
        catch (JsonException ex)
        {
            throw new InvalidOperationException("The service account key is not valid JSON.", ex);
        }

        return type == JsonCredentialParameters.ServiceAccountCredentialType
            ? text
            : throw new InvalidOperationException($"The key is a \"{type ?? "unknown"}\" credential, not a service account key.");
    }

    private GoogleCredential ServiceAccount(string json) =>
        WithHttp(CredentialFactory.FromJson<ServiceAccountCredential>(json).ToGoogleCredential().CreateScoped(LoginScope));

    private async Task<GoogleCredential> ApplicationDefaultAsync()
    {
        // A user login keeps the scopes it was granted; gcloud's default login includes the one Cloud SQL accepts.
        var credential = await GoogleCredential.GetApplicationDefaultAsync(CancellationToken.None);
        return WithHttp(credential.CreateScoped(LoginScope));
    }

    private GoogleCredential WithHttp(GoogleCredential credential) => _http is null ? credential : credential.CreateWithHttpClientFactory(_http);

    private static string Message(Exception ex) => ex switch
    {
        TokenResponseException { Error.Error: "invalid_scope" } =>
            "The gcloud login does not allow Cloud SQL sign-in. Run gcloud auth application-default login again, without --scopes.",
        TokenResponseException { Error.Error: "invalid_grant" } =>
            $"Google refused the credentials: {ex.Message} Run gcloud auth application-default login, or check the service account key, and connect again.",
        InvalidOperationException when ex.Message.Contains("Application Default Credentials", StringComparison.OrdinalIgnoreCase) =>
            "No Google application default credentials were found. Run gcloud auth application-default login and connect again.",
        _ => $"Google Cloud IAM sign-in failed: {ex.Message}",
    };

    private static string Fingerprint(string text) => Convert.ToHexString(SHA256.HashData(Encoding.UTF8.GetBytes(text)));
}
