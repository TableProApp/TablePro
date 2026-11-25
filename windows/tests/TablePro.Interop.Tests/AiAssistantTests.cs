using TablePro.Testing;

namespace TablePro.Interop.Tests;

public sealed class AiAssistantTests : IAsyncLifetime
{
    private readonly string _directory = Directory.CreateTempSubdirectory("tablepro-ai-").FullName;
    private readonly MemorySecretStore _secrets = new();
    private TableProCore _core = null!;
    private DatabaseSession _session = null!;

    private string DatabasePath => Path.Combine(_directory, "shop.sqlite");

    public async ValueTask InitializeAsync()
    {
        _core = TableProCore.Create(new HostConfiguration("test", Path.Combine(_directory, "storage")), _secrets);
        _session = await _core.OpenFileAsync(new FileOpenOptions(DatabasePath, Create: true));
        await using (var editor = await _session.OpenEditorAsync())
        {
            using var run = editor.Run(
                "CREATE TABLE customers (id INTEGER PRIMARY KEY, name TEXT NOT NULL); " +
                "CREATE TABLE orders (id INTEGER PRIMARY KEY, customer_id INTEGER, total REAL); " +
                "INSERT INTO customers (name) VALUES ('Ada Lovelace')");
            Assert.IsType<QueryOutcome.Completed>(await run.Completion);
        }

        // The catalog sees tables an editor made once it reads again, as the tree's refresh does.
        await _session.RefreshObjectsAsync(ObjectScope.DefaultSchema);
    }

    public async ValueTask DisposeAsync()
    {
        await _session.DisposeAsync();
        _core.Dispose();
        Directory.Delete(_directory, recursive: true);
    }

    private static AiChat Question(string text) => new("system", [new AiMessage(AiRole.User, text)]);

    private static AiSettings Compatible(FakeAiServer server) =>
        new(AiProvider.OpenAICompatible, "test-model", server.Address);

    private static async Task<List<AiReplyEvent>> ReadAsync(AiReply reply)
    {
        using var timeout = new CancellationTokenSource(TimeSpan.FromSeconds(30));
        var events = new List<AiReplyEvent>();
        await foreach (var replyEvent in reply.ReadEventsAsync(timeout.Token))
        {
            events.Add(replyEvent);
        }

        return events;
    }

    [Fact]
    public void EachProviderSaysWhereItsRequestsGo()
    {
        Assert.Equal(
            [AiProvider.Anthropic, AiProvider.OpenAI, AiProvider.OpenAICompatible],
            AiAssistant.Providers.Select(info => info.Provider));
        Assert.Equal("api.anthropic.com", AiAssistant.HostOf(new AiSettings(AiProvider.Anthropic, "m", "http://elsewhere/v1")));
        Assert.Equal("gpu-box", AiAssistant.HostOf(new AiSettings(AiProvider.OpenAICompatible, "m", "http://gpu-box:11434/v1")));
        Assert.True(AiAssistant.IsValidAddress("http://localhost:11434/v1"));
        Assert.False(AiAssistant.IsValidAddress("localhost:11434/v1"));
        Assert.Contains("SELEC 1", AiAssistant.ActionMessage(AiAction.Fix, "SELEC 1", "syntax error"), StringComparison.Ordinal);
    }

    [Fact]
    public async Task AReplyStreamsWithTheKeyKeptInTheStore()
    {
        using var server = new FakeAiServer("SELECT name FROM customers;");
        var assistant = _core.Assistant;

        await assistant.SetKeyAsync(AiProvider.OpenAICompatible, " sk-local ");
        var hasKey = await assistant.HasKeyAsync(AiProvider.OpenAICompatible);
        var events = await ReadAsync(assistant.Reply(_session, Compatible(server), Question("names?")));
        await assistant.SetKeyAsync(AiProvider.OpenAICompatible, "");

        Assert.True(hasKey);
        Assert.False(await assistant.HasKeyAsync(AiProvider.OpenAICompatible));
        Assert.Null(_secrets.LoadItem(SecretItem.OpenAICompatibleKey));
        Assert.Equal("SELECT name FROM customers;", string.Concat(events.OfType<AiReplyEvent.Text>().Select(text => text.Part)));
        Assert.Equal(new AiReplyEvent.Finished(AiStop.Complete, 120, 30), events[^1]);
        var request = Assert.Single(server.Seen);
        Assert.Equal("/v1/chat/completions", request.Path);
        Assert.Equal("Bearer sk-local", request.Headers["authorization"]);
        Assert.Contains("names?", request.Body, StringComparison.Ordinal);
    }

    [Fact]
    public async Task ARefusedKeyNamesTheHostAndKeepsTheProvidersWords()
    {
        using var server = new FakeAiServer("", status: 401, error: "invalid api key");

        var events = await ReadAsync(_core.Assistant.Reply(_session, Compatible(server), Question("hello")));

        var failed = Assert.IsType<AiReplyEvent.Failed>(Assert.Single(events));
        Assert.Equal("ai.unauthorized", failed.Error.Code);
        Assert.Equal("127.0.0.1", failed.Error.Ai?.Host);
        Assert.Equal("invalid api key", failed.Error.Server?.Message);
    }

    [Fact]
    public async Task AConversationCarriesTheStructureOfTheTablesItNamesAndNoRow()
    {
        var started = await _core.Assistant.StartConversationAsync(
            _session,
            new AiConversationRequest("SQLite", "Which customers have no orders?"),
            TestContext.Current.CancellationToken);

        Assert.Equal(["customers", "orders"], started.Described);
        Assert.Contains("\"customers\" (\"id\" INTEGER primary key, \"name\" TEXT not null)", started.System, StringComparison.Ordinal);
        Assert.DoesNotContain("Ada Lovelace", started.System, StringComparison.Ordinal);
    }

    [Fact]
    public async Task UnderNeverTheCoreSendsNothing()
    {
        using var server = new FakeAiServer("never sent");
        var saved = await _core.Library.SaveAsync(
            new SavedConnection(null, "shop", "sqlite", "", 0, DatabasePath, "", TlsSettings.Disabled)
            {
                AiPolicy = AiPolicy.Never,
            },
            ConnectionSecrets.None);
        await using var session = await _core.ConnectAsync(
            saved.Id!.Value,
            cancellationToken: TestContext.Current.CancellationToken);

        var refused = await Assert.ThrowsAsync<TableProException>(() => _core.Assistant.StartConversationAsync(
            session,
            new AiConversationRequest("SQLite", "orders"),
            TestContext.Current.CancellationToken));
        var events = await ReadAsync(_core.Assistant.Reply(session, Compatible(server), Question("orders?")));

        Assert.Equal(AiPolicy.Never, saved.AiPolicy);
        Assert.Equal("ai.blocked", refused.Code);
        Assert.Equal("ai.blocked", Assert.IsType<AiReplyEvent.Failed>(Assert.Single(events)).Error.Code);
        Assert.Empty(server.Seen);
    }

    [Fact]
    public async Task ASaveThatLeavesThePolicyOutKeepsTheOneStored()
    {
        var library = _core.Library;

        var created = await library.SaveAsync(
            new SavedConnection(null, "shop", "sqlite", "", 0, DatabasePath, "", TlsSettings.Disabled),
            ConnectionSecrets.None);
        var allowed = await library.SaveAsync(created with { AiPolicy = AiPolicy.Allow }, ConnectionSecrets.None);
        var renamed = await library.SaveAsync(allowed with { Name = "shop (prod)", AiPolicy = null }, ConnectionSecrets.None);

        Assert.Equal(AiPolicy.Ask, created.AiPolicy);
        Assert.Equal(AiPolicy.Allow, allowed.AiPolicy);
        Assert.Equal(AiPolicy.Allow, renamed.AiPolicy);
    }

    [Fact]
    public async Task TheModelsComeBackSorted()
    {
        using var server = new FakeAiServer("", models: ["qwen3", "llama3.2:latest"]);

        var models = await _core.Assistant.ListModelsAsync(Compatible(server), TestContext.Current.CancellationToken);

        Assert.Equal(["llama3.2:latest", "qwen3"], models.Select(model => model.Id));
        Assert.All(models, model => Assert.False(model.IsOffline || model.IsDefault));
    }

    [Fact]
    public void AHostedProviderHasOfflineModelsAndADefaultAndTheCompatibleServerHasNone()
    {
        foreach (var provider in new[] { AiProvider.Anthropic, AiProvider.OpenAI })
        {
            var offline = _core.Assistant.OfflineModels(provider);
            var preferred = _core.Assistant.DefaultModel(provider);

            Assert.All(offline, model => Assert.True(model.IsOffline));
            Assert.Contains(offline, model => model.Id == preferred);
        }

        Assert.Empty(_core.Assistant.OfflineModels(AiProvider.OpenAICompatible));
        Assert.Null(_core.Assistant.DefaultModel(AiProvider.OpenAICompatible));
    }
}
