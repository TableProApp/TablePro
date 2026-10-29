using System.Net;
using System.Net.Http.Json;
using System.Text.Json;
using System.Text.Json.Serialization.Metadata;
using TablePro.Core.Licensing;
using TablePro.Storage.Localization;

namespace TablePro.Storage.Licensing;

/// <summary>The license service the macOS app talks to. Every failure arrives as a <see cref="LicenseException"/>.</summary>
public interface ILicenseApiClient
{
    Task<SignedLicensePayload> ActivateAsync(LicenseClientRequest request, CancellationToken cancellationToken = default);

    Task<SignedLicensePayload> AcceptInviteAsync(LicenseInviteRequest request, CancellationToken cancellationToken = default);

    Task<SignedLicensePayload> ValidateAsync(LicenseClientRequest request, CancellationToken cancellationToken = default);

    Task<LicenseActivations> ListActivationsAsync(LicenseClientRequest request, CancellationToken cancellationToken = default);

    /// <summary>
    /// The roster of a Team license, read with the same credential validation uses. Invites and removals sit behind a
    /// token-authenticated API the app cannot sign in to, so the app only reads it.
    /// </summary>
    Task<LicenseTeam> TeamAsync(LicenseClientRequest request, CancellationToken cancellationToken = default);

    Task DeactivateAsync(LicenseDeactivationRequest request, CancellationToken cancellationToken = default);
}

/// <summary>The endpoints under <c>https://api.tablepro.app/v1/license</c>, with the macOS client's reading of each status code.</summary>
public sealed class HttpLicenseApiClient(HttpClient http) : ILicenseApiClient
{
    public static readonly Uri DefaultBaseAddress = new("https://api.tablepro.app/v1/license/");

    public Uri BaseAddress { get; init; } = DefaultBaseAddress;

    public Task<SignedLicensePayload> ActivateAsync(LicenseClientRequest request, CancellationToken cancellationToken = default) =>
        PostAsync("activate", request, LicenseJson.ClientRequest, LicenseJson.Signed, cancellationToken);

    public Task<SignedLicensePayload> AcceptInviteAsync(LicenseInviteRequest request, CancellationToken cancellationToken = default) =>
        PostAsync("accept-invite", request, LicenseJson.InviteRequest, LicenseJson.Signed, cancellationToken);

    public Task<SignedLicensePayload> ValidateAsync(LicenseClientRequest request, CancellationToken cancellationToken = default) =>
        PostAsync("validate", request, LicenseJson.ClientRequest, LicenseJson.Signed, cancellationToken);

    public Task<LicenseActivations> ListActivationsAsync(LicenseClientRequest request, CancellationToken cancellationToken = default) =>
        PostAsync("activations", request, LicenseJson.ClientRequest, LicenseJson.Activations, cancellationToken);

    public Task<LicenseTeam> TeamAsync(LicenseClientRequest request, CancellationToken cancellationToken = default) =>
        PostAsync("team", request, LicenseJson.ClientRequest, LicenseJson.Team, cancellationToken);

    public Task DeactivateAsync(LicenseDeactivationRequest request, CancellationToken cancellationToken = default) =>
        PostAsync("deactivate", request, LicenseJson.DeactivationRequest, LicenseJson.Message, cancellationToken);

    private async Task<TResponse> PostAsync<TRequest, TResponse>(string path, TRequest body, JsonTypeInfo<TRequest> requestType, JsonTypeInfo<TResponse> responseType, CancellationToken cancellationToken)
    {
        using var request = new HttpRequestMessage(HttpMethod.Post, new Uri(BaseAddress, path))
        {
            Content = JsonContent.Create(body, requestType),
        };
        request.Headers.Accept.ParseAdd("application/json");

        HttpResponseMessage response;
        try
        {
            response = await http.SendAsync(request, cancellationToken);
        }
        catch (HttpRequestException ex)
        {
            throw new LicenseException(LicenseErrorKind.Network, ex.Message, ex);
        }
        catch (TaskCanceledException ex) when (!cancellationToken.IsCancellationRequested)
        {
            // HttpClient reports its own timeout as a cancellation; only the caller's token is a real one.
            throw new LicenseException(LicenseErrorKind.Network, ex.Message, ex);
        }

        using (response)
        {
            var content = await response.Content.ReadAsByteArrayAsync(cancellationToken);
            if (response.IsSuccessStatusCode)
            {
                try
                {
                    return JsonSerializer.Deserialize(content, responseType)
                        ?? throw new LicenseException(LicenseErrorKind.Decoding, StorageStrings.Get("License/EmptyResponse"));
                }
                catch (JsonException ex)
                {
                    throw new LicenseException(LicenseErrorKind.Decoding, ex.Message, ex);
                }
            }

            throw ToException((int)response.StatusCode, ErrorMessage(content), response.ReasonPhrase);
        }
    }

    /// <summary>The error a status code and body mean, as the macOS client reads them.</summary>
    internal static LicenseException ToException(int status, string? message, string? reason)
    {
        switch (status)
        {
            // Only a body this API wrote means the key is unknown. A captive portal or proxy answering 404 is a
            // transport failure, not a revoked license.
            case (int)HttpStatusCode.NotFound:
                return message is null
                    ? new LicenseException(LicenseErrorKind.Server, "Not Found", statusCode: status)
                    : new LicenseException(LicenseErrorKind.InvalidKey, message, statusCode: status);
            case (int)HttpStatusCode.Conflict:
                return new LicenseException(LicenseErrorKind.ActivationLimitReached, message ?? StorageStrings.Get("License/ActivationLimit"), statusCode: status);
            case (int)HttpStatusCode.Forbidden when message is not null:
                var lower = message.ToLowerInvariant();
                var kind = lower.Contains("suspend", StringComparison.Ordinal) ? LicenseErrorKind.LicenseSuspended
                    : lower.Contains("expir", StringComparison.Ordinal) ? LicenseErrorKind.LicenseExpired
                    : lower.Contains("not activated", StringComparison.Ordinal) || lower.Contains("not found", StringComparison.Ordinal) ? LicenseErrorKind.NotActivated
                    : LicenseErrorKind.Server;
                return new LicenseException(kind, message, statusCode: status);
            case (int)HttpStatusCode.Forbidden:
                return new LicenseException(LicenseErrorKind.Server, "Forbidden", statusCode: status);
            default:
                return new LicenseException(LicenseErrorKind.Server, message ?? reason ?? StorageStrings.Get("License/RequestFailed"), statusCode: status);
        }
    }

    private static string? ErrorMessage(byte[] content)
    {
        try
        {
            return content.Length == 0 ? null : JsonSerializer.Deserialize(content, LicenseJson.Message)?.Message;
        }
        catch (JsonException)
        {
            return null;
        }
    }
}
