using Native = TablePro.Interop.Native;

namespace TablePro.Interop;

public enum AiProvider
{
    Anthropic,
    OpenAI,

    // Ollama, and any other server that speaks OpenAI's Chat Completions.
    OpenAICompatible,
}

// What the assistant may send from a connection. Saved with it; a new connection starts at Ask.
public enum AiPolicy
{
    // The window asks before the first request, and the answer lasts until it disconnects.
    Ask,
    Allow,

    // Nothing from the connection goes into a prompt, which the core refuses too.
    Never,
}

public enum AiAction
{
    Explain,
    Review,
    Optimize,

    // Correct a statement the server refused, with its error.
    Fix,
}

public enum AiRole
{
    User,
    Assistant,
}

public sealed record AiProviderInfo(AiProvider Provider, string DefaultBaseUrl, bool RequiresKey, bool TakesAddress);

// A model the provider offers, merged with TablePro's model catalog. Name is null when neither names it; IsOffline
// when it comes from the catalog only, because the provider's own list was not read.
public sealed record AiModelInfo(string Id, string? Name, bool IsDeprecated, bool IsDefault, bool IsOffline);

// Address is read for OpenAICompatible only, where null is its default; the hosted providers go to their own.
public sealed record AiSettings(AiProvider Provider, string Model, string? Address = null);

public sealed record AiMessage(AiRole Role, string Text);

// One turn's request: the system prompt the conversation started with and every message so far.
public sealed record AiChat(string System, IReadOnlyList<AiMessage> Messages);

// Asked is the question or the statement, whose table names pick the structure sent; Editor is the editor's text for
// a typed question. Database is the one the editor runs in, null for the connection's. Engine is its display name.
public sealed record AiConversationRequest(string Engine, string Asked, string? Editor = null, string? Database = null);

// The system prompt a conversation keeps, and the tables whose structure it carries.
public sealed record AiConversationStart(string System, IReadOnlyList<string> Described);

// The fields of an ai.* error; the provider's own words are in CoreError.Server. Detail is the transport's English.
public sealed record AiFailure(string? Host, int? Status, AiProvider? Provider, string? Detail);

// The providers, their keys in Credential Manager, and the replies. A key never comes back from the core.
public sealed class AiAssistant
{
    private readonly Native.AiAssistant _assistant;

    internal AiAssistant(Native.AiAssistant assistant)
    {
        _assistant = assistant;
    }

    // In the order a settings page lists them.
    public static IReadOnlyList<AiProviderInfo> Providers { get; } =
        [.. Native.CoreMethods.AiProviders().Select(Mapping.ProviderInfo)];

    // The user's message for an editor action; error is the server's, for Fix.
    public static string ActionMessage(AiAction action, string statement, string? error = null)
    {
        ArgumentNullException.ThrowIfNull(statement);
        return Native.CoreMethods.AiActionMessage(Mapping.Action(action), statement, error);
    }

    // The host the settings send requests to, to name where the data goes; null for an address with none.
    public static string? HostOf(AiSettings settings)
    {
        ArgumentNullException.ThrowIfNull(settings);
        return Native.CoreMethods.AiHostOf(Mapping.Settings(settings));
    }

    // An http or https URL with a host and no query, as a request takes it.
    public static bool IsValidAddress(string address)
    {
        ArgumentNullException.ThrowIfNull(address);
        return Native.CoreMethods.AiAddressIsValid(address);
    }

    public Task<bool> HasKeyAsync(AiProvider provider) =>
        CoreCall.RunAsync(() => _assistant.HasKey(Mapping.Provider(provider)));

    // A blank key removes the one kept.
    public Task SetKeyAsync(AiProvider provider, string key)
    {
        ArgumentNullException.ThrowIfNull(key);
        return CoreCall.RunAsync(() => _assistant.SetKey(Mapping.Provider(provider), key));
    }

    // In the order to show them, the default first and deprecated ones last. Throws TableProException with an ai.*
    // code, or a secret.* one when the key cannot be read; OfflineModels then gives the catalog's.
    public async Task<IReadOnlyList<AiModelInfo>> ListModelsAsync(
        AiSettings settings,
        CancellationToken cancellationToken = default)
    {
        ArgumentNullException.ThrowIfNull(settings);
        var native = Mapping.Settings(settings);
        var models = await CoreCall.RunAsync(token => _assistant.ListModels(native, token), cancellationToken)
            .ConfigureAwait(false);
        return [.. models.Select(Mapping.ModelInfo)];
    }

    // The catalog's models for the provider, each offline; none for OpenAICompatible.
    public IReadOnlyList<AiModelInfo> OfflineModels(AiProvider provider) =>
        [.. CoreCall.Run(() => _assistant.OfflineModels(Mapping.Provider(provider))).Select(Mapping.ModelInfo)];

    // The model an empty setting takes on first use; null for OpenAICompatible.
    public string? DefaultModel(AiProvider provider) =>
        CoreCall.Run(() => _assistant.DefaultModel(Mapping.Provider(provider)));

    // Reads the catalog, never a row. Throws TableProException with ai.blocked when the connection's policy is Never.
    public async Task<AiConversationStart> StartConversationAsync(
        DatabaseSession session,
        AiConversationRequest request,
        CancellationToken cancellationToken = default)
    {
        ArgumentNullException.ThrowIfNull(session);
        ArgumentNullException.ThrowIfNull(request);
        var native = new Native.AiConversationArg(request.Engine, request.Asked, request.Editor, request.Database);
        var started = await CoreCall.RunAsync(
                token => _assistant.StartConversation(session.Handle, native, token),
                cancellationToken)
            .ConfigureAwait(false);
        return new AiConversationStart(started.System, started.Described);
    }

    // Returns at once; a refusal, a missing key or a failed request is the reply's Failed event.
    public AiReply Reply(DatabaseSession session, AiSettings settings, AiChat chat)
    {
        ArgumentNullException.ThrowIfNull(session);
        ArgumentNullException.ThrowIfNull(settings);
        ArgumentNullException.ThrowIfNull(chat);
        var wake = new ReplyWake();
        var reply = CoreCall.Run(() => _assistant.Reply(
            session.Handle,
            Mapping.Settings(settings),
            Mapping.Chat(chat),
            wake));
        return new AiReply(reply, wake);
    }
}
