using TablePro.Core.Import;
using TablePro.Storage.Import;

namespace TablePro.Storage.Tests;

public sealed class ImportMappingStoreTests : IDisposable
{
    private readonly TempDirectory _temp = new();

    private static CancellationToken Token => TestContext.Current.CancellationToken;

    public void Dispose() => _temp.Dispose();

    private static Dictionary<string, ImportMappingOverride> Overrides(params (string Field, string? Column)[] entries) =>
        entries.ToDictionary(e => e.Field, e => new ImportMappingOverride(e.Column), StringComparer.Ordinal);

    [Fact]
    public async Task RemembersAMappingPerTableAcrossInstances()
    {
        var scope = new ImportMappingScope(Guid.NewGuid(), "app", "public", "users");
        using (var store = new ImportMappingStore(_temp.Paths))
        {
            await store.RememberAsync(scope, Overrides(("mail", "email"), ("notes", null)), ["mail", "notes"], Token);
        }

        using var reopened = new ImportMappingStore(_temp.Paths);
        var saved = await reopened.OverridesAsync(scope, Token);

        Assert.Equal("email", saved["mail"].Column);
        Assert.Equal(ImportMappingOverride.Skip, saved["notes"]);
        Assert.Empty(await reopened.OverridesAsync(scope with { Table = "orders" }, Token));
        Assert.Empty(await reopened.OverridesAsync(scope with { Schema = "audit" }, Token));
    }

    [Fact]
    public async Task FoldsEachImportIntoWhatTheTableAlreadyHas()
    {
        var scope = new ImportMappingScope(Guid.NewGuid(), null, null, "users");
        using var store = new ImportMappingStore(_temp.Paths);
        await store.RememberAsync(scope, Overrides(("legacy_code", "code")), ["legacy_code"], Token);

        await store.RememberAsync(scope, Overrides(("mail", "email")), ["mail"], Token);
        var saved = await store.OverridesAsync(scope, Token);

        Assert.Equal("code", saved["legacy_code"].Column);
        Assert.Equal("email", saved["mail"].Column);
    }

    [Fact]
    public async Task AMappingBackToTheNameMatchForgetsTheTable()
    {
        var scope = new ImportMappingScope(Guid.NewGuid(), "app", null, "users");
        using var store = new ImportMappingStore(_temp.Paths);
        await store.RememberAsync(scope, Overrides(("mail", "email")), ["mail"], Token);

        await store.RememberAsync(scope, Overrides(), ["mail"], Token);

        Assert.Empty(await store.OverridesAsync(scope, Token));
        Assert.DoesNotContain("users", await File.ReadAllTextAsync(_temp.File(ImportMappingStore.FileName), Token), StringComparison.Ordinal);
    }

    [Fact]
    public async Task ForgetsEverythingADeletedConnectionSaved()
    {
        var kept = new ImportMappingScope(Guid.NewGuid(), null, null, "a");
        var dropped = new ImportMappingScope(Guid.NewGuid(), null, null, "b");
        using var store = new ImportMappingStore(_temp.Paths);
        await store.RememberAsync(kept, Overrides(("x", "y")), ["x"], Token);
        await store.RememberAsync(dropped, Overrides(("x", "y")), ["x"], Token);

        await store.ForgetConnectionAsync(dropped.ConnectionId, Token);

        Assert.NotEmpty(await store.OverridesAsync(kept, Token));
        Assert.Empty(await store.OverridesAsync(dropped, Token));
    }

    [Fact]
    public async Task AHandEditedFileMissingPartsStillLoads()
    {
        var id = Guid.NewGuid();
        await File.WriteAllTextAsync(
            _temp.File(ImportMappingStore.FileName),
            $$"""{ "mappings": [ { "connectionId": "{{id}}", "table": "t" }, { "connectionId": "{{id}}", "table": "u", "fields": { "a": "b", }, }, ] }""",
            Token);
        using var store = new ImportMappingStore(_temp.Paths);

        Assert.Empty(await store.OverridesAsync(new ImportMappingScope(id, null, null, "t"), Token));
        Assert.Equal("b", (await store.OverridesAsync(new ImportMappingScope(id, null, null, "u"), Token))["a"].Column);
    }
}
