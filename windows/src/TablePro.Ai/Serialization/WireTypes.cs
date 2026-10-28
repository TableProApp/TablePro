using System.Text.Json.Serialization;

namespace TablePro.Ai.Serialization;

internal sealed record ErrorBody
{
    [JsonPropertyName("type")]
    public string? Type { get; init; }

    [JsonPropertyName("message")]
    public string? Message { get; init; }
}

internal sealed record AnthropicRequest
{
    [JsonPropertyName("model")]
    public required string Model { get; init; }

    [JsonPropertyName("max_tokens")]
    public required int MaxTokens { get; init; }

    [JsonPropertyName("system")]
    public string? System { get; init; }

    [JsonPropertyName("messages")]
    public required AnthropicMessage[] Messages { get; init; }

    [JsonPropertyName("temperature")]
    public double? Temperature { get; init; }

    [JsonPropertyName("stream")]
    public bool Stream { get; init; }
}

internal sealed record AnthropicMessage(
    [property: JsonPropertyName("role")] string Role,
    [property: JsonPropertyName("content")] string Content);

internal sealed record AnthropicStreamEvent
{
    [JsonPropertyName("type")]
    public string? Type { get; init; }

    [JsonPropertyName("delta")]
    public AnthropicDelta? Delta { get; init; }

    [JsonPropertyName("error")]
    public ErrorBody? Error { get; init; }
}

internal sealed record AnthropicDelta
{
    [JsonPropertyName("type")]
    public string? Type { get; init; }

    [JsonPropertyName("text")]
    public string? Text { get; init; }
}

internal sealed record AnthropicModelList
{
    [JsonPropertyName("data")]
    public AnthropicModel[]? Data { get; init; }

    [JsonPropertyName("has_more")]
    public bool HasMore { get; init; }

    [JsonPropertyName("last_id")]
    public string? LastId { get; init; }
}

internal sealed record AnthropicModel
{
    [JsonPropertyName("id")]
    public string? Id { get; init; }

    [JsonPropertyName("display_name")]
    public string? DisplayName { get; init; }
}

internal sealed record OpenAIChatRequest
{
    [JsonPropertyName("model")]
    public required string Model { get; init; }

    [JsonPropertyName("messages")]
    public required OpenAIMessage[] Messages { get; init; }

    [JsonPropertyName("stream")]
    public bool Stream { get; init; }

    [JsonPropertyName("stream_options")]
    public OpenAIStreamOptions? StreamOptions { get; init; }

    [JsonPropertyName("max_tokens")]
    public int? MaxTokens { get; init; }

    [JsonPropertyName("max_completion_tokens")]
    public int? MaxCompletionTokens { get; init; }

    [JsonPropertyName("temperature")]
    public double? Temperature { get; init; }
}

internal sealed record OpenAIMessage(
    [property: JsonPropertyName("role")] string Role,
    [property: JsonPropertyName("content")] string Content);

internal sealed record OpenAIStreamOptions([property: JsonPropertyName("include_usage")] bool IncludeUsage);

internal sealed record OpenAIStreamChunk
{
    [JsonPropertyName("choices")]
    public OpenAIChoice[]? Choices { get; init; }

    [JsonPropertyName("error")]
    public ErrorBody? Error { get; init; }
}

internal sealed record OpenAIChoice
{
    [JsonPropertyName("delta")]
    public OpenAIDelta? Delta { get; init; }

    [JsonPropertyName("finish_reason")]
    public string? FinishReason { get; init; }
}

internal sealed record OpenAIDelta
{
    [JsonPropertyName("content")]
    public string? Content { get; init; }
}

internal sealed record OpenAIModelList
{
    [JsonPropertyName("data")]
    public OpenAIModel[]? Data { get; init; }
}

internal sealed record OpenAIModel
{
    [JsonPropertyName("id")]
    public string? Id { get; init; }
}

internal sealed record GeminiRequest
{
    [JsonPropertyName("systemInstruction")]
    public GeminiContent? SystemInstruction { get; init; }

    [JsonPropertyName("contents")]
    public required GeminiContent[] Contents { get; init; }

    [JsonPropertyName("generationConfig")]
    public GeminiGenerationConfig? GenerationConfig { get; init; }
}

internal sealed record GeminiContent
{
    [JsonPropertyName("role")]
    public string? Role { get; init; }

    [JsonPropertyName("parts")]
    public GeminiPart[]? Parts { get; init; }
}

internal sealed record GeminiPart
{
    [JsonPropertyName("text")]
    public string? Text { get; init; }

    /// <summary>Set on a thinking model's thought summary, which is not part of the answer.</summary>
    [JsonPropertyName("thought")]
    public bool? Thought { get; init; }
}

internal sealed record GeminiGenerationConfig
{
    [JsonPropertyName("maxOutputTokens")]
    public int? MaxOutputTokens { get; init; }

    [JsonPropertyName("temperature")]
    public double? Temperature { get; init; }
}

internal sealed record GeminiStreamChunk
{
    [JsonPropertyName("candidates")]
    public GeminiCandidate[]? Candidates { get; init; }

    [JsonPropertyName("error")]
    public ErrorBody? Error { get; init; }
}

internal sealed record GeminiCandidate
{
    [JsonPropertyName("content")]
    public GeminiContent? Content { get; init; }

    [JsonPropertyName("finishReason")]
    public string? FinishReason { get; init; }
}

internal sealed record GeminiModelList
{
    [JsonPropertyName("models")]
    public GeminiModel[]? Models { get; init; }

    [JsonPropertyName("nextPageToken")]
    public string? NextPageToken { get; init; }
}

internal sealed record GeminiModel
{
    [JsonPropertyName("name")]
    public string? Name { get; init; }

    [JsonPropertyName("displayName")]
    public string? DisplayName { get; init; }

    [JsonPropertyName("supportedGenerationMethods")]
    public string[]? SupportedGenerationMethods { get; init; }
}

[JsonSourceGenerationOptions(DefaultIgnoreCondition = JsonIgnoreCondition.WhenWritingNull)]
[JsonSerializable(typeof(AnthropicRequest))]
[JsonSerializable(typeof(AnthropicStreamEvent))]
[JsonSerializable(typeof(AnthropicModelList))]
[JsonSerializable(typeof(OpenAIChatRequest))]
[JsonSerializable(typeof(OpenAIStreamChunk))]
[JsonSerializable(typeof(OpenAIModelList))]
[JsonSerializable(typeof(GeminiRequest))]
[JsonSerializable(typeof(GeminiStreamChunk))]
[JsonSerializable(typeof(GeminiModelList))]
internal sealed partial class AiJsonContext : JsonSerializerContext;
