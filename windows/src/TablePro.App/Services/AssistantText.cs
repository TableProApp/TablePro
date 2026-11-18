using TablePro.Interop;

namespace TablePro.App.Services;

// The assistant's words: providers, where requests go, and each ai.* code with its host, status and provider.
internal static class AssistantText
{
    public static string ProviderName(AiProvider provider) => Strings.Get(provider switch
    {
        AiProvider.Anthropic => "AiProviderAnthropic",
        AiProvider.OpenAI => "AiProviderOpenAI",
        _ => "AiProviderCompatible",
    });

    // The provider and the host its requests go to, as the question before the first request names them.
    public static string Destination(AiSettings settings)
    {
        ArgumentNullException.ThrowIfNull(settings);
        var host = AiAssistant.HostOf(settings);
        return (settings.Provider, host) switch
        {
            (AiProvider.OpenAICompatible, { } named) => Strings.Format("AiDestinationServer", named),
            (_, { } named) => Strings.Format("AiDestinationProvider", ProviderName(settings.Provider), named),
            _ => ProviderName(settings.Provider),
        };
    }

    public static string Action(AiAction action) => Strings.Get(action switch
    {
        AiAction.Explain => "AiExplain",
        AiAction.Review => "AiReview",
        AiAction.Optimize => "AiOptimize",
        _ => "AiFix",
    });

    // A code with no sentence of its own here, a secret.* one included, is worded as every other error is.
    public static string Error(CoreError error)
    {
        ArgumentNullException.ThrowIfNull(error);
        var ai = error.Ai;
        var host = ai?.Host ?? string.Empty;
        var detail = ai?.Detail ?? string.Empty;
        var sentence = error.Code switch
        {
            "ai.missing_key" => Strings.Format(
                "AiError_missing_key",
                ai?.Provider is { } provider ? ProviderName(provider) : string.Empty),
            "ai.missing_model" => Strings.Get("AiError_missing_model"),
            "ai.invalid_address" => Strings.Get("AiError_invalid_address"),
            "ai.key_over_plain_http" => Strings.Get("AiError_key_over_plain_http"),
            "ai.invalid_key" => Strings.Get("AiError_invalid_key"),
            "ai.tls" => Strings.Format("AiError_tls", detail),
            "ai.unreachable" => Strings.Format("AiError_unreachable", host, detail),
            "ai.timed_out" => Strings.Format("AiError_timed_out", host),
            "ai.unauthorized" => Strings.Format("AiError_unauthorized", host),
            "ai.rate_limited" => Strings.Format("AiError_rate_limited", host),
            "ai.status" => Strings.Format("AiError_status", host, ai?.Status ?? 0),
            // The provider's own words are the sentence.
            "ai.provider" => Strings.Format("AiError_provider", error.Server?.Message ?? string.Empty),
            "ai.protocol" => Strings.Format("AiError_protocol", detail),
            "ai.too_long" => Strings.Get("AiError_too_long"),
            "ai.blocked" => Strings.Get("AiError_blocked"),
            _ => null,
        };
        if (sentence is null)
        {
            return Strings.Error(error);
        }

        return error.Code != "ai.provider" && error.Server?.Message is { Length: > 0 } said
            ? Strings.Format("AiErrorServerSaid", sentence, said)
            : sentence;
    }
}
