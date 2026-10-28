using System.Net;
using TablePro.Ai.Providers;

namespace TablePro.Ai.Tests;

public sealed class ProviderTests
{
    private static readonly AiChatRequest Request = new()
    {
        Model = "test-model",
        SystemPrompt = "Be brief.",
        Messages = [AiMessage.User("Hi"), AiMessage.Assistant("Hello"), AiMessage.User("Explain SELECT 1")],
        MaxTokens = 1000,
    };

    [Fact]
    public async Task AnthropicSendsTheMessagesApiShapeAndStreamsTextDeltas()
    {
        using var handler = new FakeHttpHandler().RespondSse("""
            event: message_start
            data: {"type":"message_start","message":{"id":"m"}}

            event: ping
            data: {"type":"ping"}

            event: content_block_delta
            data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"Hel"}}

            event: content_block_delta
            data: {"type":"content_block_delta","index":0,"delta":{"type":"thinking_delta","thinking":"hmm"}}

            event: content_block_delta
            data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"lo"}}

            event: message_stop
            data: {"type":"message_stop"}

            data: {"type":"content_block_delta","delta":{"type":"text_delta","text":"after stop"}}


            """);
        using var client = handler.CreateClient();
        var provider = new AnthropicProvider("sk-ant-test", httpClient: client);

        var text = await Collect(provider.StreamChatAsync(Request, TestContext.Current.CancellationToken));

        Assert.Equal("Hello", text);
        var sent = Assert.Single(handler.Requests);
        Assert.Equal(HttpMethod.Post, sent.Method);
        Assert.Equal("https://api.anthropic.com/v1/messages", sent.Uri.ToString());
        Assert.Equal("sk-ant-test", sent.Headers["x-api-key"]);
        Assert.Equal("2023-06-01", sent.Headers["anthropic-version"]);
        Assert.False(sent.Headers.ContainsKey("Authorization"));
        var body = sent.Json;
        Assert.Equal("test-model", body.GetProperty("model").GetString());
        Assert.Equal(1000, body.GetProperty("max_tokens").GetInt32());
        Assert.Equal("Be brief.", body.GetProperty("system").GetString());
        Assert.True(body.GetProperty("stream").GetBoolean());
        Assert.False(body.TryGetProperty("temperature", out _));
        var messages = body.GetProperty("messages").EnumerateArray().ToArray();
        Assert.Equal(["user", "assistant", "user"], messages.Select(m => m.GetProperty("role").GetString()));
        Assert.Equal("Explain SELECT 1", messages[2].GetProperty("content").GetString());
    }

    [Fact]
    public void AnthropicDefaultsToSonnet()
    {
        var provider = new AnthropicProvider("key");

        Assert.Equal("claude-sonnet-5-5", provider.DefaultModel);
    }

    [Fact]
    public async Task AnthropicErrorEventMidStreamThrows()
    {
        using var handler = new FakeHttpHandler().RespondSse("""
            event: content_block_delta
            data: {"type":"content_block_delta","delta":{"type":"text_delta","text":"partial"}}

            event: error
            data: {"type":"error","error":{"type":"overloaded_error","message":"Overloaded"}}


            """);
        using var client = handler.CreateClient();
        var provider = new AnthropicProvider("key", httpClient: client);

        var ex = await Assert.ThrowsAsync<AiProviderException>(() => Collect(provider.StreamChatAsync(Request, TestContext.Current.CancellationToken)));

        Assert.Contains("Overloaded", ex.Message, StringComparison.Ordinal);
    }

    [Fact]
    public async Task UnauthorizedAnswerBecomesAnAuthenticationError()
    {
        using var handler = new FakeHttpHandler().Respond(HttpStatusCode.Unauthorized, """{"type":"error","error":{"type":"authentication_error","message":"invalid x-api-key"}}""");
        using var client = handler.CreateClient();
        var provider = new AnthropicProvider("bad", httpClient: client);

        var ex = await Assert.ThrowsAsync<AiProviderException>(() => Collect(provider.StreamChatAsync(Request, TestContext.Current.CancellationToken)));

        Assert.Equal(AiErrorKind.Authentication, ex.Kind);
        Assert.Equal(HttpStatusCode.Unauthorized, ex.StatusCode);
        Assert.Contains("invalid x-api-key", ex.Message, StringComparison.Ordinal);
    }

    [Fact]
    public async Task AnthropicModelListFollowsPages()
    {
        using var handler = new FakeHttpHandler()
            .Respond(HttpStatusCode.OK, """{"data":[{"id":"claude-opus-5-5","display_name":"Claude Opus 5.5"}],"has_more":true,"last_id":"claude-opus-5-5"}""")
            .Respond(HttpStatusCode.OK, """{"data":[{"id":"claude-sonnet-5-5","display_name":"Claude Sonnet 5.5"}],"has_more":false}""");
        using var client = handler.CreateClient();
        var provider = new AnthropicProvider("key", httpClient: client);

        var models = await provider.ListModelsAsync(TestContext.Current.CancellationToken);

        Assert.Equal(["claude-opus-5-5", "claude-sonnet-5-5"], models.Select(m => m.Id));
        Assert.Equal("Claude Opus 5.5", models[0].DisplayName);
        Assert.Equal("https://api.anthropic.com/v1/models?limit=1000", handler.Requests[0].Uri.ToString());
        Assert.Equal("https://api.anthropic.com/v1/models?limit=1000&after_id=claude-opus-5-5", handler.Requests[1].Uri.ToString());
        Assert.Equal(HttpMethod.Get, handler.Requests[0].Method);
        Assert.Equal("2023-06-01", handler.Requests[0].Headers["anthropic-version"]);
    }

    [Fact]
    public async Task OpenAISendsChatCompletionsWithBearerAndCompletionTokenCap()
    {
        using var handler = new FakeHttpHandler().RespondSse("""
            data: {"choices":[{"delta":{"role":"assistant"}}]}

            data: {"choices":[{"delta":{"content":"SEL"}}]}

            data: {"choices":[{"delta":{"content":"ECT 1"},"finish_reason":"stop"}]}

            data: {"choices":[],"usage":{"total_tokens":5}}

            data: [DONE]


            """);
        using var client = handler.CreateClient();
        var provider = new OpenAIProvider("sk-test", httpClient: client);

        var text = await Collect(provider.StreamChatAsync(Request, TestContext.Current.CancellationToken));

        Assert.Equal("SELECT 1", text);
        var sent = Assert.Single(handler.Requests);
        Assert.Equal("https://api.openai.com/v1/chat/completions", sent.Uri.ToString());
        Assert.Equal("Bearer sk-test", sent.Headers["Authorization"]);
        var body = sent.Json;
        Assert.Equal(1000, body.GetProperty("max_completion_tokens").GetInt32());
        Assert.False(body.TryGetProperty("max_tokens", out _));
        Assert.True(body.GetProperty("stream_options").GetProperty("include_usage").GetBoolean());
        var messages = body.GetProperty("messages").EnumerateArray().ToArray();
        Assert.Equal(["system", "user", "assistant", "user"], messages.Select(m => m.GetProperty("role").GetString()));
        Assert.Equal("Be brief.", messages[0].GetProperty("content").GetString());
    }

    [Fact]
    public async Task OllamaUsesLocalAddressWithoutKeyAndTheOldTokenCap()
    {
        using var handler = new FakeHttpHandler().RespondSse("data: {\"choices\":[{\"delta\":{\"content\":\"ok\"}}]}\n\ndata: [DONE]\n\n");
        using var client = handler.CreateClient();
        var provider = new OpenAICompatibleProvider(httpClient: client);

        var text = await Collect(provider.StreamChatAsync(Request, TestContext.Current.CancellationToken));

        Assert.Equal("ok", text);
        var sent = Assert.Single(handler.Requests);
        Assert.Equal("http://localhost:11434/v1/chat/completions", sent.Uri.ToString());
        Assert.False(sent.Headers.ContainsKey("Authorization"));
        var body = sent.Json;
        Assert.Equal(1000, body.GetProperty("max_tokens").GetInt32());
        Assert.False(body.TryGetProperty("max_completion_tokens", out _));
        Assert.False(body.TryGetProperty("stream_options", out _));
    }

    [Fact]
    public async Task CompatibleServerKeepsItsPathAndSendsAnOptionalKey()
    {
        using var handler = new FakeHttpHandler()
            .Respond(HttpStatusCode.OK, """{"data":[{"id":"zeta"},{"id":"alpha"}]}""");
        using var client = handler.CreateClient();
        var provider = new OpenAICompatibleProvider(new Uri("https://llm.example.com/api/v1"), "secret", "LM Server", client);

        var models = await provider.ListModelsAsync(TestContext.Current.CancellationToken);

        Assert.Equal(["alpha", "zeta"], models.Select(m => m.Id));
        Assert.Equal("https://llm.example.com/api/v1/models", handler.Requests[0].Uri.ToString());
        Assert.Equal("Bearer secret", handler.Requests[0].Headers["Authorization"]);
        Assert.Equal("LM Server", provider.DisplayName);
    }

    [Fact]
    public void KeyOverPlainHttpToAnotherMachineIsRefused()
    {
        Assert.Throws<ArgumentException>(() => new OpenAICompatibleProvider(new Uri("http://192.168.1.20:11434/v1"), "secret"));

        _ = new OpenAICompatibleProvider(new Uri("http://127.0.0.1:11434/v1"), "secret");
        _ = new OpenAICompatibleProvider(new Uri("http://192.168.1.20:11434/v1"));
    }

    [Fact]
    public async Task GeminiSendsGenerateContentAndSkipsThoughts()
    {
        using var handler = new FakeHttpHandler().RespondSse("""
            data: {"candidates":[{"content":{"role":"model","parts":[{"text":"thinking...","thought":true}]}}]}

            data: {"candidates":[{"content":{"role":"model","parts":[{"text":"Hi "},{"text":"there"}]}}]}

            data: {"candidates":[{"content":{"role":"model","parts":[{"text":"!"}]},"finishReason":"STOP"}]}


            """);
        using var client = handler.CreateClient();
        var provider = new GeminiProvider("g-key", httpClient: client);

        var text = await Collect(provider.StreamChatAsync(Request with { Model = "models/gemini-2.5-pro" }, TestContext.Current.CancellationToken));

        Assert.Equal("Hi there!", text);
        var sent = Assert.Single(handler.Requests);
        Assert.Equal("https://generativelanguage.googleapis.com/v1beta/models/gemini-2.5-pro:streamGenerateContent?alt=sse", sent.Uri.ToString());
        Assert.Equal("g-key", sent.Headers["x-goog-api-key"]);
        var body = sent.Json;
        Assert.Equal("Be brief.", body.GetProperty("systemInstruction").GetProperty("parts")[0].GetProperty("text").GetString());
        var contents = body.GetProperty("contents").EnumerateArray().ToArray();
        Assert.Equal(["user", "model", "user"], contents.Select(c => c.GetProperty("role").GetString()));
        Assert.Equal(1000, body.GetProperty("generationConfig").GetProperty("maxOutputTokens").GetInt32());
    }

    [Fact]
    public async Task GeminiModelListKeepsChatModelsOnly()
    {
        using var handler = new FakeHttpHandler().Respond(HttpStatusCode.OK, """
            {"models":[
              {"name":"models/gemini-2.5-flash","displayName":"Gemini 2.5 Flash","supportedGenerationMethods":["generateContent","countTokens"]},
              {"name":"models/text-embedding-004","supportedGenerationMethods":["embedContent"]}
            ]}
            """);
        using var client = handler.CreateClient();
        var provider = new GeminiProvider("g-key", httpClient: client);

        var models = await provider.ListModelsAsync(TestContext.Current.CancellationToken);

        var model = Assert.Single(models);
        Assert.Equal("gemini-2.5-flash", model.Id);
        Assert.Equal("Gemini 2.5 Flash", model.Label);
    }

    [Fact]
    public void FactoryBuildsTheNamedProvider()
    {
        Assert.IsType<AnthropicProvider>(AiProviderFactory.Create(new AiProviderSettings { Kind = AiProviderKind.Anthropic, ApiKey = "k" }));
        Assert.IsType<OpenAIProvider>(AiProviderFactory.Create(new AiProviderSettings { Kind = AiProviderKind.OpenAI, ApiKey = "k" }));
        Assert.IsType<GeminiProvider>(AiProviderFactory.Create(new AiProviderSettings { Kind = AiProviderKind.Gemini, ApiKey = "k" }));
        Assert.IsType<OpenAICompatibleProvider>(AiProviderFactory.Create(new AiProviderSettings { Kind = AiProviderKind.OpenAICompatible }));
        Assert.Throws<ArgumentException>(() => AiProviderFactory.Create(new AiProviderSettings { Kind = AiProviderKind.Anthropic }));
    }

    [Fact]
    public async Task TemperatureIsSentOnlyWhenSet()
    {
        using var handler = new FakeHttpHandler().RespondSse("data: [DONE]\n\n");
        using var client = handler.CreateClient();
        var provider = new OpenAIProvider("k", httpClient: client);

        await Collect(provider.StreamChatAsync(Request with { Temperature = 0.2 }, TestContext.Current.CancellationToken));

        Assert.Equal(0.2, handler.Requests[0].Json.GetProperty("temperature").GetDouble());
    }

    private static async Task<string> Collect(IAsyncEnumerable<string> stream)
    {
        var text = new System.Text.StringBuilder();
        await foreach (var delta in stream)
        {
            text.Append(delta);
        }

        return text.ToString();
    }
}
