using System.Net.Http.Json;
using System.Text.Json;
using System.Text.Json.Serialization.Metadata;

namespace TablePro.Storage.Library.Team;

/// <summary>The team library service: one shared set of connections and saved queries per team license.</summary>
public interface ITeamLibraryApiClient
{
    Task<TeamLibraryPullResponse> PullAsync(TeamLibraryCredentials credentials, CancellationToken cancellationToken = default);

    Task<TeamLibraryPublishResponse> PublishAsync(TeamLibraryPublishRequest request, CancellationToken cancellationToken = default);

    Task DeleteConnectionAsync(string id, TeamLibraryCredentials credentials, CancellationToken cancellationToken = default);

    Task DeleteQueryAsync(string clientId, TeamLibraryCredentials credentials, CancellationToken cancellationToken = default);

    Task DeleteQueryFolderAsync(string clientId, TeamLibraryCredentials credentials, CancellationToken cancellationToken = default);
}

/// <summary>The service refused a request; <see cref="Exception.Message"/> is its own explanation when it gave one.</summary>
public sealed class TeamLibraryException : Exception
{
    public TeamLibraryException()
    {
    }

    public TeamLibraryException(string message)
        : base(message)
    {
    }

    public TeamLibraryException(string message, Exception innerException)
        : base(message, innerException)
    {
    }

    public TeamLibraryException(int statusCode, string message)
        : base(message)
    {
        StatusCode = statusCode;
    }

    public int? StatusCode { get; }
}

/// <summary>The same endpoints the macOS app calls, under <c>https://api.tablepro.app/v1/license/library</c>.</summary>
public sealed class HttpTeamLibraryApiClient(HttpClient http) : ITeamLibraryApiClient
{
    public static readonly Uri DefaultBaseAddress = new("https://api.tablepro.app/v1/license/library/");

    public Uri BaseAddress { get; init; } = DefaultBaseAddress;

    public Task<TeamLibraryPullResponse> PullAsync(TeamLibraryCredentials credentials, CancellationToken cancellationToken = default) =>
        SendAsync(HttpMethod.Post, "pull", ToRequest(credentials), LibraryJson.PullRequest, LibraryJson.PullResponse, cancellationToken);

    public Task<TeamLibraryPublishResponse> PublishAsync(TeamLibraryPublishRequest request, CancellationToken cancellationToken = default) =>
        SendAsync(HttpMethod.Post, "publish", request, LibraryJson.PublishRequest, LibraryJson.PublishResponse, cancellationToken);

    public Task DeleteConnectionAsync(string id, TeamLibraryCredentials credentials, CancellationToken cancellationToken = default) =>
        DeleteAsync("connections/" + Uri.EscapeDataString(id), credentials, cancellationToken);

    public Task DeleteQueryAsync(string clientId, TeamLibraryCredentials credentials, CancellationToken cancellationToken = default) =>
        DeleteAsync("queries/" + Uri.EscapeDataString(clientId), credentials, cancellationToken);

    public Task DeleteQueryFolderAsync(string clientId, TeamLibraryCredentials credentials, CancellationToken cancellationToken = default) =>
        DeleteAsync("query-folders/" + Uri.EscapeDataString(clientId), credentials, cancellationToken);

    private static TeamLibraryPullRequest ToRequest(TeamLibraryCredentials credentials) => new(credentials.LicenseKey, credentials.MachineId);

    private async Task DeleteAsync(string path, TeamLibraryCredentials credentials, CancellationToken cancellationToken)
    {
        using var response = await SendRawAsync(HttpMethod.Delete, path, ToRequest(credentials), LibraryJson.PullRequest, cancellationToken);
    }

    private async Task<TResponse> SendAsync<TRequest, TResponse>(HttpMethod method, string path, TRequest body, JsonTypeInfo<TRequest> requestType, JsonTypeInfo<TResponse> responseType, CancellationToken cancellationToken)
    {
        using var response = await SendRawAsync(method, path, body, requestType, cancellationToken);
        try
        {
            return await response.Content.ReadFromJsonAsync(responseType, cancellationToken)
                ?? throw new TeamLibraryException("The team library returned an empty response.");
        }
        catch (JsonException ex)
        {
            throw new TeamLibraryException("The team library returned a response TablePro cannot read.", ex);
        }
    }

    private async Task<HttpResponseMessage> SendRawAsync<TRequest>(HttpMethod method, string path, TRequest body, JsonTypeInfo<TRequest> requestType, CancellationToken cancellationToken)
    {
        using var request = new HttpRequestMessage(method, new Uri(BaseAddress, path))
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
            throw new TeamLibraryException("The team library could not be reached: " + ex.Message, ex);
        }

        if (response.IsSuccessStatusCode)
        {
            return response;
        }

        using (response)
        {
            string message;
            try
            {
                message = (await response.Content.ReadFromJsonAsync(LibraryJson.Error, cancellationToken))?.Message ?? response.ReasonPhrase ?? "The request failed.";
            }
            catch (JsonException)
            {
                message = response.ReasonPhrase ?? "The request failed.";
            }

            throw new TeamLibraryException((int)response.StatusCode, message);
        }
    }
}
