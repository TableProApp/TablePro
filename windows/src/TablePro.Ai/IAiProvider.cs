namespace TablePro.Ai;

public enum AiProviderKind
{
    Anthropic,
    OpenAI,

    /// <summary>Ollama or any server that speaks OpenAI's chat completions at an address the user enters.</summary>
    OpenAICompatible,
    Gemini,
}

/// <summary>A chat model service. Implementations are stateless and safe to share between windows.</summary>
public interface IAiProvider
{
    AiProviderKind Kind { get; }

    /// <summary>The name the approval prompt shows, such as <c>Anthropic</c>.</summary>
    string DisplayName { get; }

    /// <summary>Where requests go, which the approval prompt shows beside the name.</summary>
    Uri BaseAddress { get; }

    string DefaultModel { get; }

    /// <summary>Streams the reply's text as it arrives. Throws <see cref="AiProviderException"/> when the provider refuses.</summary>
    IAsyncEnumerable<string> StreamChatAsync(AiChatRequest request, CancellationToken cancellationToken = default);

    Task<IReadOnlyList<AiModelInfo>> ListModelsAsync(CancellationToken cancellationToken = default);
}

/// <summary>What the preferences page stores for the chosen provider. The key comes from the credential vault.</summary>
public sealed record AiProviderSettings
{
    public required AiProviderKind Kind { get; init; }

    public string? ApiKey { get; init; }

    /// <summary>Null takes the provider's own address.</summary>
    public Uri? BaseAddress { get; init; }

    /// <summary>Null takes the provider's default model.</summary>
    public string? Model { get; init; }
}
