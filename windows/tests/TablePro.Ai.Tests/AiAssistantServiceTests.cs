using System.Runtime.CompilerServices;
using TablePro.Ai.Assistant;
using TablePro.Ai.Conversations;
using TablePro.Ai.Prompts;
using TablePro.Core.Connections;

namespace TablePro.Ai.Tests;

public sealed class AiAssistantServiceTests
{
    [Fact]
    public async Task NeverRefusesWithoutSendingOrAsking()
    {
        var provider = new FakeProvider("ignored");
        var asked = 0;
        var service = new AiAssistantService(provider, (_, _) => { asked++; return ValueTask.FromResult(true); });
        var conversation = new AiConversation();

        var ex = await Assert.ThrowsAsync<AiAccessDeniedException>(() => Drain(service.SendAsync(conversation, "hi", Context(AiPolicy.Never), TestContext.Current.CancellationToken)));

        Assert.Equal(AiAccessDenial.PolicyNever, ex.Reason);
        Assert.Empty(provider.Requests);
        Assert.Equal(0, asked);
        Assert.Equal(0, conversation.Count);
    }

    [Fact]
    public async Task AllowSendsWithoutAsking()
    {
        var provider = new FakeProvider("Hello", " there");
        var service = new AiAssistantService(provider, (_, _) => throw new InvalidOperationException("must not ask"));
        var conversation = new AiConversation();

        var reply = await Drain(service.SendAsync(conversation, "hi", Context(AiPolicy.Allow), TestContext.Current.CancellationToken));

        Assert.Equal("Hello there", reply);
        Assert.Single(provider.Requests);
        Assert.Equal([AiRole.User, AiRole.Assistant], conversation.Messages.Select(m => m.Role));
        Assert.Equal("Hello there", conversation.Messages[1].Content);
    }

    [Fact]
    public async Task AskEachTimeAsksOnceAndRemembersTheAnswer()
    {
        var provider = new FakeProvider("ok");
        var requests = new List<AiApprovalRequest>();
        var service = new AiAssistantService(provider, (request, _) => { requests.Add(request); return ValueTask.FromResult(true); });
        var context = Context(AiPolicy.AskEachTime);
        var conversation = new AiConversation();

        await Drain(service.SendAsync(conversation, "one", context, TestContext.Current.CancellationToken));
        await Drain(service.SendAsync(conversation, "two", context, TestContext.Current.CancellationToken));

        var asked = Assert.Single(requests);
        Assert.Equal("Fake", asked.ProviderName);
        Assert.Equal(context.Profile!.Id, asked.Profile.Id);
        Assert.Equal(2, provider.Requests.Count);
        Assert.True(service.GetRememberedDecision(context.Profile.Id));
    }

    [Fact]
    public async Task DeclinedAskSendsNothingAndIsRemembered()
    {
        var provider = new FakeProvider("ok");
        var asked = 0;
        var service = new AiAssistantService(provider, (_, _) => { asked++; return ValueTask.FromResult(false); });
        var context = Context(AiPolicy.AskEachTime);

        var first = await Assert.ThrowsAsync<AiAccessDeniedException>(() => Drain(service.SendAsync(new AiConversation(), "hi", context, TestContext.Current.CancellationToken)));
        await Assert.ThrowsAsync<AiAccessDeniedException>(() => Drain(service.SendAsync(new AiConversation(), "again", context, TestContext.Current.CancellationToken)));

        Assert.Equal(AiAccessDenial.Declined, first.Reason);
        Assert.Equal(1, asked);
        Assert.Empty(provider.Requests);

        service.ForgetDecision(context.Profile!.Id);
        await Assert.ThrowsAsync<AiAccessDeniedException>(() => Drain(service.SendAsync(new AiConversation(), "after reset", context, TestContext.Current.CancellationToken)));
        Assert.Equal(2, asked);
    }

    [Fact]
    public async Task AskEachTimeWithoutAnApproverRefuses()
    {
        var provider = new FakeProvider("ok");
        var service = new AiAssistantService(provider);

        var ex = await Assert.ThrowsAsync<AiAccessDeniedException>(() => Drain(service.SendAsync(new AiConversation(), "hi", Context(AiPolicy.AskEachTime), TestContext.Current.CancellationToken)));

        Assert.Equal(AiAccessDenial.NoApprover, ex.Reason);
        Assert.Empty(provider.Requests);
    }

    [Fact]
    public async Task ConcurrentRequestsShareOnePrompt()
    {
        var provider = new FakeProvider("ok");
        var gate = new TaskCompletionSource<bool>(TaskCreationOptions.RunContinuationsAsynchronously);
        var asked = 0;
        var service = new AiAssistantService(provider, async (_, ct) => { Interlocked.Increment(ref asked); return await gate.Task.WaitAsync(ct); });
        var context = Context(AiPolicy.AskEachTime);

        var first = Drain(service.SendAsync(new AiConversation(), "a", context, TestContext.Current.CancellationToken));
        var second = Drain(service.SendAsync(new AiConversation(), "b", context, TestContext.Current.CancellationToken));
        gate.SetResult(true);
        await Task.WhenAll(first, second);

        Assert.Equal(1, asked);
        Assert.Equal(2, provider.Requests.Count);
    }

    [Fact]
    public async Task FailedPromptIsAskedAgainNextTime()
    {
        var provider = new FakeProvider("ok");
        var calls = 0;
        var service = new AiAssistantService(provider, (_, _) => ++calls == 1 ? throw new InvalidOperationException("window closed") : ValueTask.FromResult(true));
        var context = Context(AiPolicy.AskEachTime);

        await Assert.ThrowsAsync<InvalidOperationException>(() => service.EnsureAccessAsync(context.Profile, TestContext.Current.CancellationToken));
        await service.EnsureAccessAsync(context.Profile, TestContext.Current.CancellationToken);

        Assert.Equal(2, calls);
    }

    [Fact]
    public async Task NeverWinsOverAnEarlierApproval()
    {
        var provider = new FakeProvider("ok");
        var service = new AiAssistantService(provider, (_, _) => ValueTask.FromResult(true));
        var profile = Profile(AiPolicy.AskEachTime);
        await service.EnsureAccessAsync(profile, TestContext.Current.CancellationToken);

        await Assert.ThrowsAsync<AiAccessDeniedException>(() => service.EnsureAccessAsync(profile with { AiPolicy = AiPolicy.Never }, TestContext.Current.CancellationToken));
    }

    [Fact]
    public async Task NoConnectionMeansNoPolicy()
    {
        var provider = new FakeProvider("ok");
        var service = new AiAssistantService(provider);

        var reply = await Drain(service.SendAsync(new AiConversation(), "what is a CTE?", AiRequestContext.None, TestContext.Current.CancellationToken));

        Assert.Equal("ok", reply);
    }

    [Fact]
    public async Task InlineSuggestionNeverPromptsAndFollowsThePolicy()
    {
        var provider = new FakeProvider("LECT * FROM t");
        var asked = 0;
        var service = new AiAssistantService(provider, (_, _) => { asked++; return ValueTask.FromResult(true); });

        var ask = await service.SuggestInlineAsync("SE", null, Context(AiPolicy.AskEachTime), TestContext.Current.CancellationToken);
        var never = await service.SuggestInlineAsync("SE", null, Context(AiPolicy.Never), TestContext.Current.CancellationToken);
        var allow = await service.SuggestInlineAsync("SE", null, Context(AiPolicy.Allow), TestContext.Current.CancellationToken);

        Assert.Null(ask);
        Assert.Null(never);
        Assert.Equal("LECT * FROM t", allow);
        Assert.Equal(0, asked);
        Assert.Single(provider.Requests);
        Assert.Equal(256, provider.Requests[0].MaxTokens);
    }

    [Fact]
    public async Task QueryActionSendsTheActionPromptWithTheSchema()
    {
        var provider = new FakeProvider("Use an index.");
        var service = new AiAssistantService(provider, options: new AiAssistantOptions { Model = "chosen-model" });
        var context = Context(AiPolicy.Allow) with { Schema = new SchemaContext { EngineName = "PostgreSQL", Tables = [SchemaContextTests.Orders()] } };
        var conversation = new AiConversation();

        await Drain(service.RunQueryActionAsync(conversation, AiQueryAction.Optimize, "SELECT * FROM orders", null, context, TestContext.Current.CancellationToken));

        var sent = Assert.Single(provider.Requests);
        Assert.Equal("chosen-model", sent.Model);
        Assert.StartsWith("Optimize this SQL query. Use the indexes", sent.Messages[^1].Content, StringComparison.Ordinal);
        Assert.Contains("\"orders\"", sent.SystemPrompt, StringComparison.Ordinal);
        Assert.Equal(2, conversation.Count);
    }

    [Fact]
    public async Task FailedRequestTakesBackTheUnansweredMessage()
    {
        var provider = new FakeProvider { Failure = new AiProviderException(AiErrorKind.Network, "offline") };
        var service = new AiAssistantService(provider);
        var conversation = new AiConversation();

        await Assert.ThrowsAsync<AiProviderException>(() => Drain(service.SendAsync(conversation, "hi", AiRequestContext.None, TestContext.Current.CancellationToken)));

        Assert.Equal(0, conversation.Count);
    }

    [Fact]
    public async Task HistoryWindowStartsAtAUserTurn()
    {
        var provider = new FakeProvider("r");
        var service = new AiAssistantService(provider, options: new AiAssistantOptions { MaxHistoryMessages = 4 });
        var conversation = new AiConversation();
        for (var i = 0; i < 5; i++)
        {
            await Drain(service.SendAsync(conversation, $"q{i}", AiRequestContext.None, TestContext.Current.CancellationToken));
        }

        var last = provider.Requests[^1].Messages;
        Assert.True(last.Count <= 4);
        Assert.Equal(AiRole.User, last[0].Role);
        Assert.Equal("q4", last[^1].Content);
    }

    private static ConnectionProfile Profile(AiPolicy policy) => new()
    {
        Name = "Shop",
        Engine = DatabaseEngine.PostgreSql,
        AiPolicy = policy,
    };

    private static AiRequestContext Context(AiPolicy policy) => new() { Profile = Profile(policy) };

    private static async Task<string> Drain(IAsyncEnumerable<string> stream)
    {
        var text = new System.Text.StringBuilder();
        await foreach (var delta in stream)
        {
            text.Append(delta);
        }

        return text.ToString();
    }

    private sealed class FakeProvider(params string[] deltas) : IAiProvider
    {
        public List<AiChatRequest> Requests { get; } = [];

        public Exception? Failure { get; init; }

        public AiProviderKind Kind => AiProviderKind.OpenAICompatible;

        public string DisplayName => "Fake";

        public Uri BaseAddress { get; } = new("http://localhost:1/");

        public string DefaultModel => "fake-model";

        public async IAsyncEnumerable<string> StreamChatAsync(AiChatRequest request, [EnumeratorCancellation] CancellationToken cancellationToken = default)
        {
            lock (Requests)
            {
                Requests.Add(request);
            }

            await Task.Yield();
            if (Failure is not null)
            {
                throw Failure;
            }

            foreach (var delta in deltas)
            {
                cancellationToken.ThrowIfCancellationRequested();
                yield return delta;
            }
        }

        public Task<IReadOnlyList<AiModelInfo>> ListModelsAsync(CancellationToken cancellationToken = default) =>
            Task.FromResult<IReadOnlyList<AiModelInfo>>([new AiModelInfo(DefaultModel)]);
    }
}
