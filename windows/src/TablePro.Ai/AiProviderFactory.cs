using TablePro.Ai.Localization;
using TablePro.Ai.Providers;

namespace TablePro.Ai;

public static class AiProviderFactory
{
    /// <summary>Builds the provider the settings name. A null client takes the shared connection pool.</summary>
    public static IAiProvider Create(AiProviderSettings settings, HttpClient? httpClient = null)
    {
        ArgumentNullException.ThrowIfNull(settings);
        return settings.Kind switch
        {
            AiProviderKind.Anthropic => new AnthropicProvider(RequireKey(settings), settings.BaseAddress, httpClient),
            AiProviderKind.OpenAI => new OpenAIProvider(RequireKey(settings), settings.BaseAddress, httpClient),
            AiProviderKind.OpenAICompatible => new OpenAICompatibleProvider(settings.BaseAddress, settings.ApiKey, httpClient: httpClient),
            AiProviderKind.Gemini => new GeminiProvider(RequireKey(settings), settings.BaseAddress, httpClient),
            _ => throw new ArgumentOutOfRangeException(nameof(settings), settings.Kind, "Unknown provider."),
        };
    }

    private static string RequireKey(AiProviderSettings settings) =>
        string.IsNullOrWhiteSpace(settings.ApiKey)
            ? throw new ArgumentException(AiStrings.Format("Provider/NeedsApiKey", settings.Kind), nameof(settings))
            : settings.ApiKey;
}
