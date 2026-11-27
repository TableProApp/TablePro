using Native = TablePro.Interop.Native;

namespace TablePro.Interop;

// The assistant's records and the AI policy saved with a connection.
internal static partial class Mapping
{
    public static Native.AiProviderTag Provider(AiProvider provider) => provider switch
    {
        AiProvider.Anthropic => Native.AiProviderTag.Anthropic,
        AiProvider.OpenAI => Native.AiProviderTag.OpenAi,
        AiProvider.OpenAICompatible => Native.AiProviderTag.OpenAiCompatible,
        _ => throw new ArgumentOutOfRangeException(nameof(provider), provider, null),
    };

    public static AiProvider Provider(Native.AiProviderTag provider) => provider switch
    {
        Native.AiProviderTag.Anthropic => AiProvider.Anthropic,
        Native.AiProviderTag.OpenAi => AiProvider.OpenAI,
        Native.AiProviderTag.OpenAiCompatible => AiProvider.OpenAICompatible,
        _ => throw new ArgumentOutOfRangeException(nameof(provider), provider, "A provider the core added after this build."),
    };

    public static Native.AiPolicyTag Policy(AiPolicy policy) => policy switch
    {
        AiPolicy.Allow => Native.AiPolicyTag.Allow,
        AiPolicy.Never => Native.AiPolicyTag.Never,
        _ => Native.AiPolicyTag.Ask,
    };

    // A policy the core added after this build reads as Never, so nothing is sent before the app knows it.
    public static AiPolicy Policy(Native.AiPolicyTag policy) => policy switch
    {
        // This app has no AI default of its own, so a connection that follows one asks; a save of Ask keeps it.
        Native.AiPolicyTag.Ask or Native.AiPolicyTag.AppDefault => AiPolicy.Ask,
        Native.AiPolicyTag.Allow => AiPolicy.Allow,
        _ => AiPolicy.Never,
    };

    public static Native.AiActionTag Action(AiAction action) => action switch
    {
        AiAction.Explain => Native.AiActionTag.Explain,
        AiAction.Review => Native.AiActionTag.Review,
        AiAction.Optimize => Native.AiActionTag.Optimize,
        AiAction.Fix => Native.AiActionTag.Fix,
        _ => throw new ArgumentOutOfRangeException(nameof(action), action, null),
    };

    public static AiProviderInfo ProviderInfo(Native.AiProviderInfo info) =>
        new(Provider(info.Provider), info.DefaultBaseUrl, info.RequiresKey, info.TakesAddress);

    public static AiModelInfo ModelInfo(Native.AiModelInfo model) =>
        new(model.Id, model.Name, model.Deprecated, model.IsDefault, model.Offline);

    public static Native.AiSettingsArg Settings(AiSettings settings) =>
        new(Provider(settings.Provider), settings.Model, settings.Address);

    public static Native.AiChatArg Chat(AiChat chat) => new(
        chat.System,
        [.. chat.Messages.Select(message => new Native.AiMessageArg(
            message.Role == AiRole.Assistant ? Native.AiRoleTag.Assistant : Native.AiRoleTag.User,
            message.Text))]);

    public static AiFailure Failure(Native.AiFailureInfo failure) => new(
        failure.Host,
        failure.Status,
        failure.Provider is { } provider ? Provider(provider) : null,
        failure.Detail);

    public static AiReplyEvent ReplyEvent(Native.AiReplyEvent replyEvent) => replyEvent switch
    {
        Native.AiReplyEvent.Text text => new AiReplyEvent.Text(text.Part),
        Native.AiReplyEvent.ToolCall call => new AiReplyEvent.ToolCall(call.Id, call.Name, call.Input),
        Native.AiReplyEvent.ToolStarted started => new AiReplyEvent.ToolStarted(started.Id),
        Native.AiReplyEvent.ToolFinished finished => new AiReplyEvent.ToolFinished(
            finished.Id,
            finished.Output,
            finished.IsError),
        Native.AiReplyEvent.Finished finished => new AiReplyEvent.Finished(
            finished.Stop switch
            {
                Native.AiStopTag.LengthLimit => AiStop.LengthLimit,
                Native.AiStopTag.Refused => AiStop.Refused,
                _ => AiStop.Complete,
            },
            finished.InputTokens is { } input ? checked((long)input) : null,
            finished.OutputTokens is { } output ? checked((long)output) : null),
        Native.AiReplyEvent.Failed failed => new AiReplyEvent.Failed(Error(failed.Error)),
        _ => AiReplyEvent.Stopped.Instance,
    };
}
