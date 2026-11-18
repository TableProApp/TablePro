using TablePro.Interop;

namespace TablePro.App.Model.Tests;

public sealed class AssistantTests
{
    private static AiSettings Compatible(string address) => new(AiProvider.OpenAICompatible, "llama3", address);

    private static readonly AiSettings Anthropic = new(AiProvider.Anthropic, "claude-opus-5-5");

    [Fact]
    public async Task WithNoProviderNothingIsAllowed()
    {
        var access = new AssistantAccess(() => null, () => AiPolicy.Allow);
        var asked = false;

        var permitted = await access.PermitAsync(_ => Task.FromResult(asked = true));

        Assert.Equal(AssistantAvailability.Off, access.Availability);
        Assert.False(permitted);
        Assert.False(asked);
    }

    [Fact]
    public async Task NeverKeepsEverythingBackWhateverWasAnsweredBefore()
    {
        var policy = AiPolicy.Ask;
        var access = new AssistantAccess(() => Anthropic, () => policy);
        Assert.True(await access.PermitAsync(_ => Task.FromResult(true)));

        policy = AiPolicy.Never;

        Assert.Equal(AssistantAvailability.Blocked, access.Availability);
        Assert.False(access.IsGranted);
        Assert.False(access.MaySendTo(Anthropic));
        Assert.False(await access.PermitAsync(_ => Task.FromResult(true)));
    }

    [Fact]
    public async Task AskEachTimeAsksOnceAndTheAnswerHolds()
    {
        var access = new AssistantAccess(() => Anthropic, () => AiPolicy.Ask);
        var questions = 0;
        Task<bool> Ask(AiSettings settings)
        {
            questions++;
            Assert.Equal(Anthropic, settings);
            return Task.FromResult(true);
        }

        Assert.False(access.IsGranted);
        Assert.True(await access.PermitAsync(Ask));
        Assert.True(await access.PermitAsync(Ask));

        Assert.Equal(1, questions);
        Assert.True(access.MaySendTo(Anthropic with { Model = "another model" }));
    }

    [Fact]
    public async Task ACancelledQuestionAllowsNothingAndAsksAgainNextTime()
    {
        var access = new AssistantAccess(() => Anthropic, () => AiPolicy.Ask);

        Assert.False(await access.PermitAsync(_ => Task.FromResult(false)));
        Assert.True(await access.PermitAsync(_ => Task.FromResult(true)));
    }

    [Fact]
    public async Task AnAnswerHoldsOnlyForTheServerItNamed()
    {
        var settings = Compatible("http://localhost:11434/v1");
        var access = new AssistantAccess(() => settings, () => AiPolicy.Ask);
        var first = settings;
        Assert.True(await access.PermitAsync(_ => Task.FromResult(true)));

        settings = Compatible("http://gpu-box:11434/v1/");
        Assert.False(access.IsGranted);
        Assert.False(access.MaySendTo(settings));
        Assert.False(access.MaySendTo(first));

        settings = Compatible("http://localhost:11434/v1/");
        Assert.True(access.MaySendTo(first));
    }

    [Fact]
    public async Task AnAllowGivenAfterTheServerChangedAllowsNothing()
    {
        var settings = Compatible("http://localhost:11434/v1");
        var access = new AssistantAccess(() => settings, () => AiPolicy.Ask);

        var allowed = await access.PermitAsync(_ =>
        {
            settings = Compatible("http://gpu-box:11434/v1");
            return Task.FromResult(true);
        });

        Assert.False(allowed);
        Assert.False(access.IsGranted);
    }

    [Fact]
    public async Task OneQuestionAtATime()
    {
        var access = new AssistantAccess(() => Anthropic, () => AiPolicy.Ask);
        var answer = new TaskCompletionSource<bool>();

        var first = access.PermitAsync(_ => answer.Task);
        var second = await access.PermitAsync(_ => Task.FromResult(true));
        answer.SetResult(true);

        Assert.False(second);
        Assert.True(await first);
    }

    [Fact]
    public void UnderAllowARequestMadeBeforeAChangeIsNotSent()
    {
        var settings = Compatible("http://localhost:11434/v1");
        var policy = AiPolicy.Allow;
        var access = new AssistantAccess(() => settings, () => policy);
        var first = settings;
        Assert.True(access.MaySendTo(first));

        settings = Compatible("http://gpu-box:11434/v1");
        Assert.False(access.MaySendTo(first));
        Assert.True(access.MaySendTo(settings));

        policy = AiPolicy.Ask;
        Assert.False(access.MaySendTo(settings));
    }

    [Fact]
    public void EachQuestionCarriesTheAnsweredTurnsBeforeIt()
    {
        var conversation = new AssistantConversation("system", ["orders"]);
        conversation.Ask(new AssistantAsk.Typed("first"), "first");
        conversation.Answer("one");
        conversation.Ask(new AssistantAsk.Typed("lost"), "lost");
        conversation.Ask(new AssistantAsk.Action(AiAction.Fix, "SELEC 1", "syntax error"), "fix it");

        var request = conversation.Request();

        Assert.Equal("system", request.System);
        Assert.Equal(
            [new AiMessage(AiRole.User, "first"), new AiMessage(AiRole.Assistant, "one"), new AiMessage(AiRole.User, "fix it")],
            request.Messages);
    }

    [Fact]
    public void ARepliedCodeBlockIsKeptApartFromItsProse()
    {
        var blocks = ReplyMarkdown.Read(
            "## Why\nThe **join** misses `NULL` keys.\n- one\n- two\n\n```sql\nSELECT *\nFROM orders;\n```\nDone.");

        Assert.Equal(4, blocks.Count);
        var heading = Assert.IsType<ReplyBlock.Paragraph>(blocks[0]);
        Assert.True(heading.IsHeading);
        Assert.Equal([new ReplySpan("Why", ReplySpanStyle.Plain)], heading.Spans);
        var prose = Assert.IsType<ReplyBlock.Paragraph>(blocks[1]);
        Assert.Equal(
            [
                new ReplySpan("The ", ReplySpanStyle.Plain),
                new ReplySpan("join", ReplySpanStyle.Bold),
                new ReplySpan(" misses ", ReplySpanStyle.Plain),
                new ReplySpan("NULL", ReplySpanStyle.Code),
                new ReplySpan(" keys.\n• one\n• two", ReplySpanStyle.Plain),
            ],
            prose.Spans);
        Assert.Equal(new ReplyBlock.Code("sql", "SELECT *\nFROM orders;"), blocks[2]);
        Assert.Equal("Done.", Assert.Single(Assert.IsType<ReplyBlock.Paragraph>(blocks[3]).Spans).Text);
    }

    [Fact]
    public void AFenceStillStreamingRunsToTheEndAndALoneMarkerIsText()
    {
        var blocks = ReplyMarkdown.Read("Try:\n````sql\nSELECT '```'\n");

        Assert.Equal(new ReplyBlock.Code("sql", "SELECT '```'\n"), blocks[1]);
        Assert.Equal([new ReplySpan("2 ** 3 and a ` tick", ReplySpanStyle.Plain)], ReplyMarkdown.Spans("2 ** 3 and a ` tick"));
    }

    [Fact]
    public void AssistantSettingsComeBackAsSavedAndStartOff()
    {
        var path = Path.Combine(Directory.CreateTempSubdirectory("tablepro-model-").FullName, "settings.json");
        var store = new SettingsStore(path);
        Assert.Null(store.Load().Assistant);

        store.Save(new AppSettings
        {
            AiProvider = AiProvider.OpenAICompatible,
            CompatibleModel = " qwen3 ",
            CompatibleAddress = " ",
        });
        var loaded = store.Load();
        File.WriteAllText(path, """{ "aiProvider": "Gemini" }""");

        Assert.Equal(new AiSettings(AiProvider.OpenAICompatible, "qwen3", AppSettings.DefaultCompatibleAddress), loaded.Assistant);
        Assert.Equal(AppSettings.DefaultAnthropicModel, loaded.ModelOf(AiProvider.Anthropic));
        Assert.Null(loaded.AssistantFor(AiProvider.Anthropic).Address);
        Assert.Null(new SettingsStore(path).Load().AiProvider);
    }

    [Fact]
    public void TheConnectionFormKeepsThePolicyAndAChangeOfItLeavesAConnectAlone()
    {
        var sqlite = new DatabaseEngine("sqlite", "SQLite", DataModel.Relational, null, ["sqlite"]);
        var saved = new SavedConnection(Guid.NewGuid(), "shop", "sqlite", "", 0, "/data/shop.sqlite", "", TlsSettings.Disabled)
        {
            AiPolicy = AiPolicy.Never,
        };

        var draft = ConnectionDraft.From(saved, sqlite);
        draft.AiPolicy = AiPolicy.Allow;
        var edited = draft.ToConnection();

        Assert.Equal(AiPolicy.Allow, edited.AiPolicy);
        Assert.Equal(AiPolicy.Ask, ConnectionDraft.New(sqlite).AiPolicy);
        Assert.False(ConnectionDraft.ChangesConnect(saved, edited));
    }
}
