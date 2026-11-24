using System.Text.Json;
using FlaUI.Core.AutomationElements;
using FlaUI.Core.Tools;
using TablePro.Testing;

namespace TablePro.App.UITests;

// The provider is a server on 127.0.0.1 that answers as Ollama does, so nothing leaves the runner.
public sealed partial class ShellTests
{
    private const string AssistantReply =
        "Each album's track count:\n\n```sql\nSELECT AlbumId, COUNT(*) AS Tracks\nFROM Track\nGROUP BY AlbumId;\n```\n\nIt reads **Track** only.";

    private const string ReplyCode = "SELECT AlbumId, COUNT(*) AS Tracks\nFROM Track\nGROUP BY AlbumId;";

    private static AppSession LaunchWithAssistant(string theme, FakeAiServer server)
    {
        var folder = AppSession.NewDataFolder(theme);
        File.WriteAllText(
            Path.Combine(folder, "settings.json"),
            JsonSerializer.Serialize(new Dictionary<string, string>
            {
                ["theme"] = theme,
                ["aiProvider"] = "OpenAICompatible",
                ["compatibleAddress"] = server.Address,
                ["compatibleModel"] = "test-model",
            }));
        return AppSession.Relaunch(folder, theme);
    }

    private static void ShowAssistant(AppSession app)
    {
        app.Click(app.Find("ViewMenu"), () => app.TryFindMenuItem("Show AI assistant") is { IsEnabled: true });
        // The pane is a UserControl, which UI Automation does not list, so its Close button stands for it.
        app.Click(app.FindMenuItem("Show AI assistant"), () => app.TryFind("AssistantCloseButton") is { IsOffscreen: false });
    }

    private static string WaitForCode(AppSession app) =>
        AppSession.WaitForText(app.Find("AssistantCode"), text => text.Contains("GROUP BY", StringComparison.Ordinal));

    [Theory]
    [MemberData(nameof(Themes))]
    public void TheAssistantStartsOffAndSettingsPicksAProviderAndItsModel(string theme)
    {
        using var server = new FakeAiServer(AssistantReply, models: ["qwen3", "test-model"]);
        using var app = AppSession.Launch(theme);

        app.Find("SettingsButton").AsButton().Invoke();
        app.Find("SettingsPage");
        var provider = app.Find("AiProviderBox").AsComboBox();
        Assert.Equal("Off", provider.SelectedItem?.Text);
        Assert.True(app.TryFind("AiKeyBox") is null or { IsOffscreen: true });

        provider.Select("Ollama or compatible server");
        provider.Collapse();
        var address = app.Find("AiAddressBox").AsTextBox();
        Assert.Equal("http://localhost:11434/v1", address.Text);
        address.Text = server.Address;
        app.Find("AiKeyBox");
        var model = app.Find("AiModelBox").AsComboBox();
        model.Focus();
        model.Expand();
        // The list is read from the server as it opens; each model is an item of the open list.
        app.FindByName("qwen3");
        app.FindByName("test-model").Patterns.SelectionItem.Pattern.Select();
        model.Collapse();
        model.Focus();
        app.Screenshot("140-settings-ai");

        Assert.Contains(server.Seen, request => request.Path == "/v1/models");
        Assert.DoesNotContain(server.Seen, request => request.Path.EndsWith("/chat/completions", StringComparison.Ordinal));
        var saved = Retry.WhileFalse(
            () => File.ReadAllText(Path.Combine(app.DataFolder, "settings.json")) is var json
                && json.Contains("\"aiProvider\": \"OpenAICompatible\"", StringComparison.Ordinal)
                && json.Contains("\"compatibleModel\": \"test-model\"", StringComparison.Ordinal),
            AppSession.Wait,
            throwOnTimeout: false).Success;
        Assert.True(saved, File.ReadAllText(Path.Combine(app.DataFolder, "settings.json")));
    }

    [Theory]
    [MemberData(nameof(Themes))]
    public void AQuestionAsksFirstThenStreamsTheReplyWithTheStructureOfTheTablesItNames(string theme)
    {
        using var server = new FakeAiServer(AssistantReply);
        using var app = LaunchWithAssistant(theme, server);

        app.Click(app.Find("SampleCard"), () => app.TryFind("Rail_Chinook (Sample)") is not null);
        app.FindByName("Track", app.Find("ObjectTree"));
        ShowAssistant(app);
        Assert.StartsWith("Questions go to the server at 127.0.0.1", AppSession.TextOf(app.Find("AssistantEmptyText")), StringComparison.Ordinal);
        app.Screenshot("141-assistant-empty");

        app.Find("AssistantComposer").AsTextBox().Text = "Count the rows of Track per Album.";
        app.Click(app.Find("AssistantSendButton"), () => app.TryFind("AssistantConsentText") is not null);
        var consent = AppSession.TextOf(app.Find("AssistantConsentText"));
        Assert.Contains("“Chinook (Sample)” to the server at 127.0.0.1", consent, StringComparison.Ordinal);
        Assert.Contains("It reads no rows.", consent, StringComparison.Ordinal);
        Assert.Empty(server.Seen);
        app.Screenshot("142-assistant-consent");
        app.PressDialogButton("Allow");

        Assert.Equal(ReplyCode, WaitForCode(app).Replace("\r", string.Empty, StringComparison.Ordinal));
        app.FindByName("Sent with the structure of Album, Track", app.Find("AssistantScroller"));
        app.FindByName("150 tokens", app.Find("AssistantScroller"));
        app.Screenshot("143-assistant-reply");

        var request = Assert.Single(server.Seen);
        var messages = JsonDocument.Parse(request.Body).RootElement.GetProperty("messages");
        var system = messages[0].GetProperty("content").GetString() ?? string.Empty;
        Assert.Contains("\"Track\" (\"TrackId\" INTEGER primary key", system, StringComparison.Ordinal);
        Assert.DoesNotContain("For Those About To Rock", request.Body, StringComparison.Ordinal);

        app.Click(app.Find("AssistantInsertCode"), () => AppSession.EditorText(app.FindEditor("Query 1")).Contains("GROUP BY", StringComparison.Ordinal));
    }

    [Theory]
    [MemberData(nameof(Themes))]
    public void ExplainWithAiSendsTheStatementAtTheCaretAndAsksOncePerConnection(string theme)
    {
        using var server = new FakeAiServer(AssistantReply);
        using var app = LaunchWithAssistant(theme, server);

        app.Click(app.Find("SampleCard"), () => app.TryFind("Rail_Chinook (Sample)") is not null);
        app.FindByName("Track", app.Find("ObjectTree"));
        app.TypeInto("Query 1", "SELECT Name FROM Track LIMIT 5;");
        app.Click(app.Find("QueryMenu"), () => app.TryFindMenuItem("Explain with AI") is { IsEnabled: true });
        app.Click(app.FindMenuItem("Explain with AI"), () => app.TryFind("AssistantConsentText") is not null);
        app.PressDialogButton("Allow");

        WaitForCode(app);
        Assert.Equal("SELECT Name FROM Track LIMIT 5;", AppSession.TextOf(app.Find("AssistantStatement")));
        app.FindByName("Explain with AI", app.Find("AssistantScroller"));
        app.Screenshot("144-assistant-explain");
        var asked = JsonDocument.Parse(Assert.Single(server.Seen).Body).RootElement.GetProperty("messages");
        Assert.StartsWith("Explain what this statement does", asked[1].GetProperty("content").GetString(), StringComparison.Ordinal);

        // The answer holds for the connection, so a second action goes without asking.
        app.Click(app.Find("QueryMenu"), () => app.TryFindMenuItem("Review with AI") is { IsEnabled: true });
        app.FindMenuItem("Review with AI").Patterns.Invoke.Pattern.Invoke();
        Assert.True(Retry.WhileFalse(() => server.Seen.Count == 2, AppSession.Wait, throwOnTimeout: false).Success);
        Assert.Null(app.TryFind("AssistantConsentText"));
        app.FindByName("Review with AI", app.Find("AssistantScroller"));
    }

    [Theory]
    [MemberData(nameof(Themes))]
    public void AConnectionWhosePolicyIsNeverSendsNothing(string theme)
    {
        using var server = new FakeAiServer(AssistantReply);
        using var app = LaunchWithAssistant(theme, server);
        var database = AppSession.SampleDatabase(app.DataFolder);

        app.Click(app.Find("NewConnectionCard"), () => app.HasWindow("New connection"));
        var form = app.WaitForWindow("New connection");
        app.Click(app.Find("Engine_sqlite", form), () => app.TryFind("FileBox", form) is not null, form);
        app.Find("FileBox", form).AsTextBox().Text = database;
        app.Find("NameBox", form).AsTextBox().Text = "Private";
        app.Click(app.Find("OptionsExpander", form), () => app.TryFind("AiPolicyBox", form) is { IsOffscreen: false }, form);
        var policy = app.Find("AiPolicyBox", form).AsComboBox();
        Assert.Equal("Ask each time", policy.SelectedItem?.Text);
        policy.Select("Never");
        policy.Collapse();
        app.Screenshot("145-connection-ai-policy", form);
        app.Find("ConnectButton", form).AsButton().Invoke();
        app.WaitForClose("New connection");

        app.FindByName("Album", app.Find("ObjectTree"));
        ShowAssistant(app);
        app.Find("AssistantBlockedText");
        Assert.True(app.TryFind("AssistantComposer") is null or { IsOffscreen: true });
        app.TypeInto("Query 1", "SELECT Name FROM Track LIMIT 5;");
        app.Click(app.Find("QueryMenu"), () => app.TryFindMenuItem("Explain with AI") is not null);
        Assert.False(app.FindMenuItem("Explain with AI").IsEnabled);
        app.Screenshot("146-assistant-blocked");
        Assert.Empty(server.Seen);
    }
}
