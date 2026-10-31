using System.Net.Http.Headers;
using System.Runtime.CompilerServices;
using TablePro.Ai.Http;
using TablePro.Ai.Localization;
using TablePro.Ai.Serialization;

namespace TablePro.Ai.Providers;

/// <summary>OpenAI's chat completions wire format, which OpenAI, Ollama and many local servers share.</summary>
public abstract class OpenAIChatProvider : HttpAiProvider
{
    private readonly string? _apiKey;

    protected OpenAIChatProvider(string? apiKey, Uri baseAddress, HttpClient? httpClient)
        : base(baseAddress, httpClient)
    {
        _apiKey = string.IsNullOrWhiteSpace(apiKey) ? null : apiKey;
    }

    /// <summary>OpenAI deprecated <c>max_tokens</c> for <c>max_completion_tokens</c>; most compatible servers know only the old name.</summary>
    protected abstract bool UsesMaxCompletionTokens { get; }

    /// <summary>Ollama and some local servers reject <c>stream_options</c>.</summary>
    protected abstract bool SendsStreamOptions { get; }

    public override async IAsyncEnumerable<string> StreamChatAsync(AiChatRequest request, [EnumeratorCancellation] CancellationToken cancellationToken = default)
    {
        ArgumentNullException.ThrowIfNull(request);
        var messages = new List<OpenAIMessage>(request.Messages.Count + 1);
        if (!string.IsNullOrEmpty(request.SystemPrompt))
        {
            messages.Add(new OpenAIMessage("system", request.SystemPrompt));
        }

        foreach (var message in request.Messages)
        {
            messages.Add(new OpenAIMessage(message.Role == AiRole.User ? "user" : "assistant", message.Content));
        }

        var body = new OpenAIChatRequest
        {
            Model = request.Model,
            Messages = [.. messages],
            Stream = true,
            StreamOptions = SendsStreamOptions ? new OpenAIStreamOptions(true) : null,
            MaxTokens = UsesMaxCompletionTokens ? null : request.MaxTokens,
            MaxCompletionTokens = UsesMaxCompletionTokens ? request.MaxTokens : null,
            Temperature = request.Temperature,
        };

        var http = JsonPost(Endpoint("chat/completions"), body, AiJsonContext.Default.OpenAIChatRequest);
        await foreach (var evt in StreamEventsAsync(http, cancellationToken))
        {
            if (evt.IsDone)
            {
                yield break;
            }

            var chunk = ParseEvent(evt, AiJsonContext.Default.OpenAIStreamChunk);
            if (chunk?.Error is { } error)
            {
                throw AiProviderException.FromStreamError(DisplayName, error);
            }

            if (chunk?.Choices is [{ Delta.Content: { Length: > 0 } text }, ..])
            {
                yield return text;
            }
        }
    }

    public override async Task<IReadOnlyList<AiModelInfo>> ListModelsAsync(CancellationToken cancellationToken = default)
    {
        var list = await GetJsonAsync(Endpoint("models"), AiJsonContext.Default.OpenAIModelList, cancellationToken);
        return [.. (list.Data ?? [])
            .Where(m => !string.IsNullOrEmpty(m.Id))
            .Select(m => new AiModelInfo(m.Id!))
            .OrderBy(m => m.Id, StringComparer.OrdinalIgnoreCase)];
    }

    protected override void AddAuthentication(HttpRequestMessage request)
    {
        if (_apiKey is not null)
        {
            request.Headers.Authorization = new AuthenticationHeaderValue("Bearer", _apiKey);
        }
    }
}

public sealed class OpenAIProvider : OpenAIChatProvider
{
    public const string DefaultModelId = "gpt-5";

    public static readonly Uri DefaultBaseAddress = new("https://api.openai.com/v1/");

    public OpenAIProvider(string apiKey, Uri? baseAddress = null, HttpClient? httpClient = null)
        : base(apiKey, baseAddress ?? DefaultBaseAddress, httpClient)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(apiKey);
    }

    public override AiProviderKind Kind => AiProviderKind.OpenAI;

    public override string DisplayName => "OpenAI";

    public override string DefaultModel => DefaultModelId;

    protected override bool UsesMaxCompletionTokens => true;

    protected override bool SendsStreamOptions => true;
}

/// <summary>Ollama or any server with an OpenAI-shaped <c>/chat/completions</c>. The key is optional.</summary>
public sealed class OpenAICompatibleProvider : OpenAIChatProvider
{
    public const string DefaultModelId = "llama3.2";

    public static readonly Uri OllamaBaseAddress = new("http://localhost:11434/v1/");

    public OpenAICompatibleProvider(Uri? baseAddress = null, string? apiKey = null, string? displayName = null, HttpClient? httpClient = null)
        : base(apiKey, baseAddress ?? OllamaBaseAddress, httpClient)
    {
        var address = baseAddress ?? OllamaBaseAddress;

        // A key over plain http to another machine would cross the network readable by anyone on the path.
        if (!string.IsNullOrWhiteSpace(apiKey) && address.Scheme == Uri.UriSchemeHttp && !address.IsLoopback)
        {
            throw new ArgumentException(AiStrings.Get("Provider/KeyOverHttp"), nameof(apiKey));
        }

        DisplayName = string.IsNullOrWhiteSpace(displayName) ? "Ollama" : displayName;
    }

    public override AiProviderKind Kind => AiProviderKind.OpenAICompatible;

    public override string DisplayName { get; }

    public override string DefaultModel => DefaultModelId;

    protected override bool UsesMaxCompletionTokens => false;

    protected override bool SendsStreamOptions => false;
}
