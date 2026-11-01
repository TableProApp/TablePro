using System.Runtime.CompilerServices;
using TablePro.Ai.Http;
using TablePro.Ai.Serialization;

namespace TablePro.Ai.Providers;

/// <summary>Google's Gemini API, streamed as server-sent events with <c>alt=sse</c>.</summary>
public sealed class GeminiProvider : HttpAiProvider
{
    public const string DefaultModelId = "gemini-2.5-flash";

    public static readonly Uri DefaultBaseAddress = new("https://generativelanguage.googleapis.com/v1beta/");

    private readonly string _apiKey;

    public GeminiProvider(string apiKey, Uri? baseAddress = null, HttpClient? httpClient = null)
        : base(baseAddress ?? DefaultBaseAddress, httpClient)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(apiKey);
        _apiKey = apiKey;
    }

    public override AiProviderKind Kind => AiProviderKind.Gemini;

    public override string DisplayName => "Google Gemini";

    public override string DefaultModel => DefaultModelId;

    public override async IAsyncEnumerable<string> StreamChatAsync(AiChatRequest request, [EnumeratorCancellation] CancellationToken cancellationToken = default)
    {
        ArgumentNullException.ThrowIfNull(request);
        var body = new GeminiRequest
        {
            SystemInstruction = string.IsNullOrEmpty(request.SystemPrompt) ? null : new GeminiContent { Parts = [new GeminiPart { Text = request.SystemPrompt }] },
            Contents = [.. request.Messages.Select(m => new GeminiContent
            {
                Role = m.Role == AiRole.User ? "user" : "model",
                Parts = [new GeminiPart { Text = m.Content }],
            })],
            GenerationConfig = new GeminiGenerationConfig { MaxOutputTokens = request.MaxTokens, Temperature = request.Temperature },
        };

        var model = Uri.EscapeDataString(StripModelsPrefix(request.Model));
        var http = JsonPost(Endpoint($"models/{model}:streamGenerateContent?alt=sse"), body, AiJsonContext.Default.GeminiRequest);
        await foreach (var evt in StreamEventsAsync(http, cancellationToken))
        {
            var chunk = ParseEvent(evt, AiJsonContext.Default.GeminiStreamChunk);
            if (chunk?.Error is { } error)
            {
                throw AiProviderException.FromStreamError(DisplayName, error);
            }

            if (chunk?.Candidates is not [{ Content.Parts: { } parts }, ..])
            {
                continue;
            }

            foreach (var part in parts)
            {
                if (part.Thought != true && !string.IsNullOrEmpty(part.Text))
                {
                    yield return part.Text;
                }
            }
        }
    }

    public override async Task<IReadOnlyList<AiModelInfo>> ListModelsAsync(CancellationToken cancellationToken = default)
    {
        var models = new List<AiModelInfo>();
        string? pageToken = null;
        for (var page = 0; page < 10; page++)
        {
            var path = pageToken is null ? "models?pageSize=1000" : $"models?pageSize=1000&pageToken={Uri.EscapeDataString(pageToken)}";
            var list = await GetJsonAsync(Endpoint(path), AiJsonContext.Default.GeminiModelList, cancellationToken);
            foreach (var model in list.Models ?? [])
            {
                // Embedding and other models answer no chat request.
                if (string.IsNullOrEmpty(model.Name) || model.SupportedGenerationMethods?.Contains("generateContent") != true)
                {
                    continue;
                }

                models.Add(new AiModelInfo(StripModelsPrefix(model.Name), model.DisplayName));
            }

            if (string.IsNullOrEmpty(list.NextPageToken))
            {
                break;
            }

            pageToken = list.NextPageToken;
        }

        return models;
    }

    protected override void AddAuthentication(HttpRequestMessage request) =>
        request.Headers.TryAddWithoutValidation("x-goog-api-key", _apiKey);

    private static string StripModelsPrefix(string model) =>
        model.StartsWith("models/", StringComparison.Ordinal) ? model["models/".Length..] : model;
}
