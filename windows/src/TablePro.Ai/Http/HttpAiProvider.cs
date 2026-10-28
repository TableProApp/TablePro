using System.Net.Http.Headers;
using System.Runtime.CompilerServices;
using System.Text.Json;
using System.Text.Json.Serialization.Metadata;
using TablePro.Ai.Sse;

namespace TablePro.Ai.Http;

/// <summary>What every HTTP provider shares: sending, error mapping, and reading an event stream.</summary>
public abstract class HttpAiProvider : IAiProvider
{
    private static readonly MediaTypeHeaderValue JsonMediaType = new("application/json") { CharSet = "utf-8" };
    private static readonly MediaTypeWithQualityHeaderValue EventStream = new("text/event-stream");

    protected HttpAiProvider(Uri baseAddress, HttpClient? httpClient)
    {
        ArgumentNullException.ThrowIfNull(baseAddress);
        BaseAddress = WithTrailingSlash(baseAddress);
        Http = httpClient ?? AiHttp.SharedClient;
    }

    public abstract AiProviderKind Kind { get; }

    public abstract string DisplayName { get; }

    public Uri BaseAddress { get; }

    public abstract string DefaultModel { get; }

    protected HttpClient Http { get; }

    public abstract IAsyncEnumerable<string> StreamChatAsync(AiChatRequest request, CancellationToken cancellationToken = default);

    public abstract Task<IReadOnlyList<AiModelInfo>> ListModelsAsync(CancellationToken cancellationToken = default);

    /// <summary>Resolves a path against the base address, keeping the base's own path, such as <c>/v1</c>.</summary>
    protected Uri Endpoint(string relativePath) => new(BaseAddress, relativePath.TrimStart('/'));

    protected abstract void AddAuthentication(HttpRequestMessage request);

    protected HttpRequestMessage JsonPost<T>(Uri uri, T body, JsonTypeInfo<T> typeInfo)
    {
        var content = new ByteArrayContent(JsonSerializer.SerializeToUtf8Bytes(body, typeInfo));
        content.Headers.ContentType = JsonMediaType;
        var request = new HttpRequestMessage(HttpMethod.Post, uri) { Content = content };
        request.Headers.Accept.Add(EventStream);
        AddAuthentication(request);
        return request;
    }

    protected async Task<T> GetJsonAsync<T>(Uri uri, JsonTypeInfo<T> typeInfo, CancellationToken cancellationToken)
    {
        using var request = new HttpRequestMessage(HttpMethod.Get, uri);
        AddAuthentication(request);
        using var response = await SendAsync(request, cancellationToken);
        await using var stream = await response.Content.ReadAsStreamAsync(cancellationToken);
        try
        {
            return await JsonSerializer.DeserializeAsync(stream, typeInfo, cancellationToken)
                ?? throw new AiProviderException(AiErrorKind.InvalidResponse, $"{DisplayName} answered with an empty body.");
        }
        catch (JsonException ex)
        {
            throw new AiProviderException(AiErrorKind.InvalidResponse, $"{DisplayName} answered with JSON the app cannot read.", null, ex);
        }
    }

    /// <summary>Sends a request whose body is an event stream and yields its events, disposing the request at the end.</summary>
    protected async IAsyncEnumerable<SseEvent> StreamEventsAsync(HttpRequestMessage request, [EnumeratorCancellation] CancellationToken cancellationToken)
    {
        using (request)
        {
            using var response = await SendAsync(request, cancellationToken);
            await using var stream = await response.Content.ReadAsStreamAsync(cancellationToken);
            await foreach (var evt in SseReader.ReadAsync(stream, cancellationToken))
            {
                yield return evt;
            }
        }
    }

    protected T? ParseEvent<T>(SseEvent evt, JsonTypeInfo<T> typeInfo)
        where T : class
    {
        try
        {
            return JsonSerializer.Deserialize(evt.Data, typeInfo);
        }
        catch (JsonException ex)
        {
            throw new AiProviderException(AiErrorKind.InvalidResponse, $"{DisplayName} sent an event the app cannot read.", null, ex);
        }
    }

    private async Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken cancellationToken)
    {
        HttpResponseMessage response;
        try
        {
            response = await Http.SendAsync(request, HttpCompletionOption.ResponseHeadersRead, cancellationToken);
        }
        catch (HttpRequestException ex)
        {
            throw new AiProviderException(AiErrorKind.Network, $"Could not reach {DisplayName} at {BaseAddress}: {ex.Message}", null, ex);
        }

        if (response.IsSuccessStatusCode)
        {
            return response;
        }

        using (response)
        {
            throw await AiProviderException.FromResponseAsync(response, DisplayName, cancellationToken);
        }
    }

    private static Uri WithTrailingSlash(Uri uri) =>
        uri.AbsolutePath.EndsWith('/') ? uri : new Uri(uri.GetLeftPart(UriPartial.Path) + "/" + uri.Query);
}
