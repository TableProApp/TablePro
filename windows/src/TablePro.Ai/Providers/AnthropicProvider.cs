using System.Runtime.CompilerServices;
using TablePro.Ai.Http;
using TablePro.Ai.Serialization;

namespace TablePro.Ai.Providers;

/// <summary>Anthropic's Messages API, streamed.</summary>
public sealed class AnthropicProvider : HttpAiProvider
{
    public const string DefaultModelId = "claude-sonnet-5-5";

    /// <summary>The stable API version the macOS app sends too; newer request fields stay opt-in behind it.</summary>
    public const string ApiVersion = "2023-06-01";

    public static readonly Uri DefaultBaseAddress = new("https://api.anthropic.com/");

    private readonly string _apiKey;

    public AnthropicProvider(string apiKey, Uri? baseAddress = null, HttpClient? httpClient = null)
        : base(baseAddress ?? DefaultBaseAddress, httpClient)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(apiKey);
        _apiKey = apiKey;
    }

    public override AiProviderKind Kind => AiProviderKind.Anthropic;

    public override string DisplayName => "Anthropic";

    public override string DefaultModel => DefaultModelId;

    public override async IAsyncEnumerable<string> StreamChatAsync(AiChatRequest request, [EnumeratorCancellation] CancellationToken cancellationToken = default)
    {
        ArgumentNullException.ThrowIfNull(request);
        var body = new AnthropicRequest
        {
            Model = request.Model,
            MaxTokens = request.MaxTokens,
            System = string.IsNullOrEmpty(request.SystemPrompt) ? null : request.SystemPrompt,
            Messages = [.. request.Messages.Select(m => new AnthropicMessage(m.Role == AiRole.User ? "user" : "assistant", m.Content))],
            Temperature = request.Temperature,
            Stream = true,
        };

        var http = JsonPost(Endpoint("v1/messages"), body, AiJsonContext.Default.AnthropicRequest);
        await foreach (var evt in StreamEventsAsync(http, cancellationToken))
        {
            var parsed = ParseEvent(evt, AiJsonContext.Default.AnthropicStreamEvent);
            switch (parsed?.Type)
            {
                case "content_block_delta" when parsed.Delta is { Type: "text_delta", Text: { Length: > 0 } text }:
                    yield return text;
                    break;
                case "error":
                    throw AiProviderException.FromStreamError(DisplayName, parsed.Error);
                case "message_stop":
                    yield break;
            }
        }
    }

    public override async Task<IReadOnlyList<AiModelInfo>> ListModelsAsync(CancellationToken cancellationToken = default)
    {
        var models = new List<AiModelInfo>();
        string? after = null;

        // The list pages; a cap stops a server that keeps answering has_more from looping forever.
        for (var page = 0; page < 10; page++)
        {
            var path = after is null ? "v1/models?limit=1000" : $"v1/models?limit=1000&after_id={Uri.EscapeDataString(after)}";
            var list = await GetJsonAsync(Endpoint(path), AiJsonContext.Default.AnthropicModelList, cancellationToken);
            foreach (var model in list.Data ?? [])
            {
                if (!string.IsNullOrEmpty(model.Id))
                {
                    models.Add(new AiModelInfo(model.Id, model.DisplayName));
                }
            }

            if (!list.HasMore || string.IsNullOrEmpty(list.LastId))
            {
                break;
            }

            after = list.LastId;
        }

        return models;
    }

    protected override void AddAuthentication(HttpRequestMessage request)
    {
        request.Headers.TryAddWithoutValidation("x-api-key", _apiKey);
        request.Headers.TryAddWithoutValidation("anthropic-version", ApiVersion);
    }
}
