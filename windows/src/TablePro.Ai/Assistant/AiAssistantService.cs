using System.Collections.Concurrent;
using System.Runtime.CompilerServices;
using System.Text;
using TablePro.Ai.Conversations;
using TablePro.Ai.Localization;
using TablePro.Ai.Prompts;
using TablePro.Core.Connections;

namespace TablePro.Ai.Assistant;

/// <summary>What a request knows about where the user is. A null profile means no connection, so no policy applies.</summary>
public sealed record AiRequestContext
{
    public static readonly AiRequestContext None = new();

    public ConnectionProfile? Profile { get; init; }

    public SchemaContext Schema { get; init; } = SchemaContext.Empty;

    public string? EditorText { get; init; }

    /// <summary>The user's own instructions for this connection, appended to the system prompt.</summary>
    public string? ConnectionRules { get; init; }
}

public sealed record AiAssistantOptions
{
    /// <summary>Null takes the provider's default model.</summary>
    public string? Model { get; init; }

    public int MaxTokens { get; init; } = 4096;

    public int InlineMaxTokens { get; init; } = 256;

    /// <summary>Older turns drop from the request, not the conversation, so a long chat stays within the context window.</summary>
    public int MaxHistoryMessages { get; init; } = 40;
}

/// <summary>
/// The assistant for one window. It holds the window's Ask Each Time answers, so create one per window and drop it
/// (or call <see cref="ForgetDecision"/>) when the window disconnects.
/// </summary>
public sealed class AiAssistantService
{
    private readonly AiApprovalCallback? _approve;
    private readonly AiAssistantOptions _options;
    private readonly ConcurrentDictionary<Guid, Lazy<Task<bool>>> _decisions = new();

    public AiAssistantService(IAiProvider provider, AiApprovalCallback? approve = null, AiAssistantOptions? options = null)
    {
        ArgumentNullException.ThrowIfNull(provider);
        Provider = provider;
        _approve = approve;
        _options = options ?? new AiAssistantOptions();
    }

    public IAiProvider Provider { get; }

    public string Model => string.IsNullOrWhiteSpace(_options.Model) ? Provider.DefaultModel : _options.Model;

    /// <summary>
    /// Throws <see cref="AiAccessDeniedException"/> unless the connection's AI policy lets a request go. Ask Each Time
    /// prompts once per connection for the life of this service; concurrent requests share the one prompt.
    /// </summary>
    public async Task EnsureAccessAsync(ConnectionProfile? profile, CancellationToken cancellationToken = default)
    {
        if (profile is null)
        {
            return;
        }

        switch (profile.AiPolicy)
        {
            case AiPolicy.Allow:
                return;
            case AiPolicy.Never:
                throw new AiAccessDeniedException(profile.Id, AiAccessDenial.PolicyNever,
                    AiStrings.Format("Assistant/TurnedOff", profile.Name));
        }

        if (_approve is null)
        {
            throw new AiAccessDeniedException(profile.Id, AiAccessDenial.NoApprover,
                AiStrings.Format("Assistant/NoWayToAsk", profile.Name, Provider.DisplayName));
        }

        var request = new AiApprovalRequest(profile, Provider.DisplayName, Provider.BaseAddress);
        var approve = _approve;
        var pending = _decisions.GetOrAdd(profile.Id, _ => new Lazy<Task<bool>>(() => AskAsync(approve, request, cancellationToken)));
        bool allowed;
        try
        {
            allowed = await pending.Value.WaitAsync(cancellationToken);
        }
        catch
        {
            // A prompt that failed or was dismissed by cancellation is no answer; the next request asks again.
            if (pending.Value.IsFaulted || pending.Value.IsCanceled)
            {
                _decisions.TryRemove(new KeyValuePair<Guid, Lazy<Task<bool>>>(profile.Id, pending));
            }

            throw;
        }

        if (!allowed)
        {
            throw new AiAccessDeniedException(profile.Id, AiAccessDenial.Declined,
                AiStrings.Format("Assistant/Declined", profile.Name, Provider.DisplayName));
        }
    }

    /// <summary>The Ask Each Time answer this service remembers for a connection, or null when it has not asked.</summary>
    public bool? GetRememberedDecision(Guid connectionId) =>
        _decisions.TryGetValue(connectionId, out var pending) && pending.IsValueCreated && pending.Value.IsCompletedSuccessfully
            ? pending.Value.Result
            : null;

    public void ForgetDecision(Guid connectionId) => _decisions.TryRemove(connectionId, out _);

    public void ForgetAllDecisions() => _decisions.Clear();

    /// <summary>Sends the user's message in the conversation and streams the reply, which joins the conversation when it ends.</summary>
    public async IAsyncEnumerable<string> SendAsync(AiConversation conversation, string userText, AiRequestContext context, [EnumeratorCancellation] CancellationToken cancellationToken = default)
    {
        ArgumentNullException.ThrowIfNull(conversation);
        ArgumentException.ThrowIfNullOrWhiteSpace(userText);
        ArgumentNullException.ThrowIfNull(context);
        await EnsureAccessAsync(context.Profile, cancellationToken);

        var system = AiPromptTemplates.ChatSystemPrompt(context.Schema, context.EditorText, context.ConnectionRules);
        await foreach (var delta in ConverseAsync(conversation, userText, system, cancellationToken))
        {
            yield return delta;
        }
    }

    /// <summary>Explain, Optimize, Review or Fix with AI. The request and its reply join the conversation as a chat turn.</summary>
    public async IAsyncEnumerable<string> RunQueryActionAsync(
        AiConversation conversation,
        AiQueryAction action,
        string statement,
        string? errorMessage,
        AiRequestContext context,
        [EnumeratorCancellation] CancellationToken cancellationToken = default)
    {
        ArgumentNullException.ThrowIfNull(conversation);
        ArgumentException.ThrowIfNullOrWhiteSpace(statement);
        ArgumentNullException.ThrowIfNull(context);
        await EnsureAccessAsync(context.Profile, cancellationToken);

        var prompt = AiPromptTemplates.QueryActionPrompt(action, statement, errorMessage, withStructure: context.Schema.Tables.Count > 0);
        var system = AiPromptTemplates.ChatSystemPrompt(context.Schema, editorText: null, context.ConnectionRules);
        await foreach (var delta in ConverseAsync(conversation, prompt, system, cancellationToken))
        {
            yield return delta;
        }
    }

    /// <summary>Asks for SQL from a description in plain words. Take the statement from the reply with <see cref="MarkdownFence.ExtractSql"/>.</summary>
    public async IAsyncEnumerable<string> GenerateSqlAsync(AiConversation conversation, string request, AiRequestContext context, [EnumeratorCancellation] CancellationToken cancellationToken = default)
    {
        ArgumentNullException.ThrowIfNull(conversation);
        ArgumentException.ThrowIfNullOrWhiteSpace(request);
        ArgumentNullException.ThrowIfNull(context);
        await EnsureAccessAsync(context.Profile, cancellationToken);

        var prompt = AiPromptTemplates.GenerateSqlPrompt(request, context.Schema);
        var system = AiPromptTemplates.ChatSystemPrompt(context.Schema, context.EditorText, context.ConnectionRules);
        await foreach (var delta in ConverseAsync(conversation, prompt, system, cancellationToken))
        {
            yield return delta;
        }
    }

    /// <summary>
    /// A completion for suggest while typing, or null. It never prompts: a dialog popping up mid-keystroke would be worse
    /// than no suggestion, so Ask Each Time suggests only once the user has answered for the connection elsewhere.
    /// </summary>
    public async Task<string?> SuggestInlineAsync(string textBefore, string? textAfter, AiRequestContext context, CancellationToken cancellationToken = default)
    {
        ArgumentNullException.ThrowIfNull(textBefore);
        ArgumentNullException.ThrowIfNull(context);
        if (context.Profile is { } profile)
        {
            var allowed = profile.AiPolicy switch
            {
                AiPolicy.Allow => true,
                AiPolicy.Never => false,
                _ => GetRememberedDecision(profile.Id) == true,
            };
            if (!allowed)
            {
                return null;
            }
        }

        if (string.IsNullOrWhiteSpace(textBefore))
        {
            return null;
        }

        var request = new AiChatRequest
        {
            Model = Model,
            SystemPrompt = AiPromptTemplates.InlineSuggestSystemPrompt(context.Schema),
            Messages = [AiMessage.User(AiPromptTemplates.InlineSuggestMessage(textBefore, textAfter))],
            MaxTokens = _options.InlineMaxTokens,
        };

        var reply = new StringBuilder();
        await foreach (var delta in Provider.StreamChatAsync(request, cancellationToken))
        {
            reply.Append(delta);
            if (reply.Length > InlineCompletion.MaxChars * 2)
            {
                break;
            }
        }

        return InlineCompletion.Clean(reply.ToString(), textBefore);
    }

    // Async so a callback that throws before its first await still yields a faulted task the catch above can see.
    private static async Task<bool> AskAsync(AiApprovalCallback approve, AiApprovalRequest request, CancellationToken cancellationToken) =>
        await approve(request, cancellationToken);

    private async IAsyncEnumerable<string> ConverseAsync(AiConversation conversation, string userText, string systemPrompt, [EnumeratorCancellation] CancellationToken cancellationToken)
    {
        var userMessage = AiMessage.User(userText);
        conversation.Add(userMessage);
        var request = new AiChatRequest
        {
            Model = Model,
            SystemPrompt = systemPrompt,
            Messages = conversation.RecentWindow(_options.MaxHistoryMessages),
            MaxTokens = _options.MaxTokens,
        };

        var reply = new StringBuilder();
        var completed = false;
        try
        {
            await foreach (var delta in Provider.StreamChatAsync(request, cancellationToken))
            {
                reply.Append(delta);
                yield return delta;
            }

            completed = true;
        }
        finally
        {
            if (reply.Length > 0)
            {
                // A reply cut off by Stop or a dropped connection stays, since the user already read it.
                conversation.Add(AiMessage.Assistant(reply.ToString()));
            }
            else if (!completed)
            {
                conversation.Remove(userMessage);
            }
        }
    }
}
