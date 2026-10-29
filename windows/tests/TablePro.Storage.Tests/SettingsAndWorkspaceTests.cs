using System.Text.Json;
using TablePro.Storage.Settings;
using TablePro.Storage.Workspace;

namespace TablePro.Storage.Tests;

public sealed class SettingsAndWorkspaceTests : IDisposable
{
    private readonly TempDirectory _temp = new();

    private static CancellationToken Token => TestContext.Current.CancellationToken;

    public void Dispose() => _temp.Dispose();

    [Fact]
    public void DefaultsMatchTheProductDecisions()
    {
        var settings = AppSettings.Default;
        Assert.Equal(AppTheme.System, settings.Theme);
        Assert.Equal(string.Empty, settings.Language);
        Assert.Equal(10_000, settings.Data.EditorRowLimit);
        Assert.Equal(500, settings.Data.TablePageSize);
        Assert.Equal("NULL", settings.Data.NullDisplayText);
        Assert.Equal(4, settings.Editor.TabSize);
        Assert.True(settings.Editor.Autocomplete);
        Assert.False(settings.Editor.VimMode);
        Assert.True(settings.ConfirmCloseDirtyTabs);
        Assert.True(settings.RestoreSessionOnLaunch);
        Assert.Equal(AiProvider.Anthropic, settings.Ai.Provider);
        Assert.False(settings.Mcp.Enabled);
        Assert.Equal(23_508, settings.Mcp.Port);
        Assert.Equal("UTF-8", settings.LastSqlImportEncoding);
    }

    [Fact]
    public async Task MissingFileLoadsDefaults()
    {
        using var store = new SettingsStore(_temp.Paths);
        Assert.Equal(AppSettings.Default, await store.LoadAsync(Token));
    }

    [Fact]
    public async Task SettingsRoundTripAndRaiseChanged()
    {
        AppSettings? raised = null;
        var changed = AppSettings.Default with
        {
            Theme = AppTheme.Dark,
            Backdrop = WindowBackdrop.Mica,
            Language = "zh-Hant",
            Editor = new EditorSettings { FontFamily = "Consolas", FontSize = 15, TabSize = 2, WordWrap = true, VimMode = true },
            Ai = new AiSettings { Provider = AiProvider.Ollama, Endpoint = "http://localhost:11434", Model = "qwen", InlineSuggestions = true },
            Mcp = new McpSettings { Enabled = true, Port = 24000 },
        };
        using (var store = new SettingsStore(_temp.Paths))
        {
            store.Changed += (_, value) => raised = value;
            await store.SaveAsync(changed, Token);
        }

        Assert.Equal(changed, raised);
        using var reloaded = new SettingsStore(_temp.Paths);
        Assert.Equal(changed, await reloaded.LoadAsync(Token));

        var json = await File.ReadAllTextAsync(_temp.Paths.SettingsFile, Token);
        using var document = JsonDocument.Parse(json);
        Assert.Equal("Dark", document.RootElement.GetProperty("theme").GetString());
        Assert.Equal("zh-Hant", document.RootElement.GetProperty("language").GetString());
        Assert.Equal("Ollama", document.RootElement.GetProperty("ai").GetProperty("provider").GetString());
    }

    [Fact]
    public async Task PartialFileKeepsDefaultsForWhatItLeavesOut()
    {
        await File.WriteAllTextAsync(_temp.Paths.SettingsFile, """
            {
              // written by hand
              "theme": "Light",
              "editor": { "fontSize": 18 },
              "unknownFutureSetting": true,
            }
            """, Token);
        using var store = new SettingsStore(_temp.Paths);

        var settings = await store.LoadAsync(Token);

        Assert.Equal(AppTheme.Light, settings.Theme);
        Assert.Equal(18, settings.Editor.FontSize);
        Assert.Equal("Cascadia Mono", settings.Editor.FontFamily);
        Assert.Equal(4, settings.Editor.TabSize);
        Assert.True(settings.Editor.Autocomplete);
        Assert.Equal(10_000, settings.Data.EditorRowLimit);
        Assert.Equal(23_508, settings.Mcp.Port);
        Assert.True(settings.RestoreSessionOnLaunch);
        Assert.Equal("UTF-8", settings.LastSqlImportEncoding);
    }

    [Fact]
    public async Task OutOfRangeValuesAreClampedOnSave()
    {
        using var store = new SettingsStore(_temp.Paths);

        var saved = await store.UpdateAsync(s => s with
        {
            Editor = s.Editor with { FontSize = 400, TabSize = 0 },
            Data = s.Data with { EditorRowLimit = -5 },
            Mcp = s.Mcp with { Port = 80 },
        }, Token);

        Assert.Equal(EditorSettings.MaxFontSize, saved.Editor.FontSize);
        Assert.Equal(1, saved.Editor.TabSize);
        Assert.Equal(1, saved.Data.EditorRowLimit);
        Assert.Equal(McpSettings.DefaultPort, saved.Mcp.Port);
        Assert.Equal(saved, store.Current);
    }

    [Fact]
    public async Task WorkspaceStateRoundTripsPerConnection()
    {
        using var store = new WorkspaceStateStore(_temp.Paths);
        var connection = Guid.NewGuid();
        var state = new WorkspaceState
        {
            ConnectionId = connection,
            SelectedIndex = 1,
            Database = "app",
            Tabs =
            [
                new WorkspaceTab { Kind = WorkspaceTabKind.Query, Title = "Query 1", QueryText = "SELECT 1;\nSELECT 2;" },
                new WorkspaceTab { Kind = WorkspaceTabKind.Table, Title = "users", Schema = "public", ObjectName = "users", IsPinned = true },
            ],
        };

        await store.SaveAsync(state, Token);
        var loaded = await store.LoadAsync(connection, Token);

        Assert.NotNull(loaded);
        Assert.Equal(state.Tabs, loaded.Tabs);
        Assert.Equal(1, loaded.SelectedIndex);
        Assert.Equal("app", loaded.Database);
        Assert.Null(await store.LoadAsync(Guid.NewGuid(), Token));

        await store.DeleteAsync(connection, Token);
        Assert.Null(await store.LoadAsync(connection, Token));
    }

    [Fact]
    public async Task WorkspaceSelectionIsClampedToTheTabsThatExist()
    {
        using var store = new WorkspaceStateStore(_temp.Paths);
        var connection = Guid.NewGuid();
        await store.SaveAsync(new WorkspaceState { ConnectionId = connection, SelectedIndex = 9, Tabs = [new WorkspaceTab { Title = "only" }] }, Token);

        Assert.Equal(0, (await store.LoadAsync(connection, Token))!.SelectedIndex);
    }

    [Fact]
    public async Task TheLastSqlImportEncodingIsRememberedAndDefaultsToUtf8()
    {
        Assert.Equal("UTF-8", AppSettings.Default.LastSqlImportEncoding);
        using (var store = new SettingsStore(_temp.Paths))
        {
            await store.UpdateAsync(s => s with { LastSqlImportEncoding = "Windows-1252" }, Token);
        }

        using var reloaded = new SettingsStore(_temp.Paths);
        Assert.Equal("Windows-1252", (await reloaded.LoadAsync(Token)).LastSqlImportEncoding);

        var blank = await reloaded.UpdateAsync(s => s with { LastSqlImportEncoding = " " }, Token);
        Assert.Equal("UTF-8", blank.LastSqlImportEncoding);
    }
}
