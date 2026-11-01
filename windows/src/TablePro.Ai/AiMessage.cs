namespace TablePro.Ai;

public enum AiRole
{
    User,
    Assistant,
}

/// <summary>One turn of a conversation. The system prompt travels apart from the turns, as every provider wants it.</summary>
public sealed record AiMessage(AiRole Role, string Content)
{
    public static AiMessage User(string content) => new(AiRole.User, content);

    public static AiMessage Assistant(string content) => new(AiRole.Assistant, content);
}

/// <summary>What one streamed reply is asked with.</summary>
public sealed record AiChatRequest
{
    public required string Model { get; init; }

    public string? SystemPrompt { get; init; }

    public required IReadOnlyList<AiMessage> Messages { get; init; }

    /// <summary>The reply's length cap in tokens. Anthropic refuses a request without one.</summary>
    public int MaxTokens { get; init; } = 4096;

    /// <summary>Left out of the request when null, since newer reasoning models refuse the parameter.</summary>
    public double? Temperature { get; init; }
}

/// <summary>A model a provider offers, as its model list names it.</summary>
public sealed record AiModelInfo(string Id, string? DisplayName = null)
{
    public string Label => string.IsNullOrWhiteSpace(DisplayName) ? Id : DisplayName;
}
