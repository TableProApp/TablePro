using System.Text.Json;
using TablePro.Storage.Settings;

namespace TablePro.Storage.Tests;

public sealed class ShortcutSettingsTests : IDisposable
{
    private readonly TempDirectory _temp = new();

    private static CancellationToken Token => TestContext.Current.CancellationToken;

    public void Dispose() => _temp.Dispose();

    [Fact]
    public void DefaultsHaveNoOverrides() => Assert.Empty(AppSettings.Default.Shortcuts);

    [Fact]
    public async Task OverridesRoundTripWithTheirIdsAndClearsIntact()
    {
        var overrides = new Dictionary<string, string>
        {
            ["newTab"] = "Ctrl+Shift+T",
            ["toggleComment"] = "Ctrl+Alt+/",
            ["closeTab"] = string.Empty,
            ["future.unknown.command"] = "F8",
        };
        AppSettings? raised = null;
        using (var store = new SettingsStore(_temp.Paths))
        {
            store.Changed += (_, value) => raised = value;
            await store.UpdateAsync(s => s with { Shortcuts = overrides }, Token);
        }

        Assert.Equal(overrides, raised?.Shortcuts);

        using var reloaded = new SettingsStore(_temp.Paths);
        var loaded = await reloaded.LoadAsync(Token);
        Assert.Equal(overrides.OrderBy(p => p.Key, StringComparer.Ordinal), loaded.Shortcuts.OrderBy(p => p.Key, StringComparer.Ordinal));

        // Ids are written as they are, not camel-cased or otherwise renamed by the property naming policy.
        var json = await File.ReadAllTextAsync(_temp.Paths.SettingsFile, Token);
        using var document = JsonDocument.Parse(json);
        var stored = document.RootElement.GetProperty("shortcuts");
        Assert.Equal("Ctrl+Shift+T", stored.GetProperty("newTab").GetString());
        Assert.Equal(string.Empty, stored.GetProperty("closeTab").GetString());
        Assert.Equal("F8", stored.GetProperty("future.unknown.command").GetString());
    }

    [Fact]
    public async Task AFileWithoutShortcutsLoadsEqualToTheDefaults()
    {
        await File.WriteAllTextAsync(_temp.Paths.SettingsFile, """{ "theme": "Dark" }""", Token);
        using var store = new SettingsStore(_temp.Paths);
        var loaded = await store.LoadAsync(Token);

        Assert.Empty(loaded.Shortcuts);
        Assert.Equal(AppSettings.Default with { Theme = AppTheme.Dark }, loaded);
    }

    [Fact]
    public async Task NullOrEmptyShortcutsNormalizeToTheSharedEmptyMap()
    {
        await File.WriteAllTextAsync(_temp.Paths.SettingsFile, """{ "shortcuts": null }""", Token);
        using var store = new SettingsStore(_temp.Paths);
        var loaded = await store.LoadAsync(Token);

        Assert.Equal(AppSettings.Default, loaded);
        Assert.Same(AppSettings.Default.Shortcuts, (AppSettings.Default with { Shortcuts = new Dictionary<string, string>() }).Normalize().Shortcuts);
    }

    [Fact]
    public async Task ResettingEveryShortcutSavesAndRaisesChanged()
    {
        using var store = new SettingsStore(_temp.Paths);
        await store.UpdateAsync(s => s with { Shortcuts = new Dictionary<string, string> { ["newTab"] = "Ctrl+Shift+T" } }, Token);

        var changes = 0;
        store.Changed += (_, _) => changes++;
        var reset = await store.UpdateAsync(s => s with { Shortcuts = new Dictionary<string, string>() }, Token);

        Assert.Empty(reset.Shortcuts);
        Assert.Equal(1, changes);
        Assert.Equal(AppSettings.Default, reset);
    }
}
