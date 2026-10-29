using TablePro.Core.Compare;
using TablePro.Storage.Compare;

namespace TablePro.Storage.Tests;

public sealed class CompareProfileStoreTests : IDisposable
{
    private readonly TempDirectory _temp = new();

    private static CancellationToken Token => TestContext.Current.CancellationToken;

    public void Dispose() => _temp.Dispose();

    private static CompareProfile Profile(string name) => new()
    {
        Name = name,
        Source = new CompareEndpointScope { ConnectionId = Guid.NewGuid(), Database = "app", Schema = "public" },
        Target = new CompareEndpointScope { ConnectionId = Guid.NewGuid(), Database = "app_staging" },
        Mode = CompareMode.Data,
        Scope = DataCompareScope.ChosenTables,
        Tables =
        [
            new CompareProfileTable
            {
                SourceSchema = "public",
                Source = "users",
                Target = "users",
                Scope = new CompareTableScope { KeyColumns = ["email"], ExcludedColumns = ["updated_at"], SourceFilter = "active", TargetFilter = string.Empty, RowLimit = 500 },
            },
            new CompareProfileTable { Source = "orders", Target = "orders_v2", IsIncluded = false },
        ],
        Options = new CompareProfileOptions { DeleteExtraRows = true, FloatTolerance = 0.01, ApplyInBatches = true },
    };

    [Fact]
    public async Task ProfilesLoadBackWithEveryTableScope()
    {
        var profile = Profile(" Nightly ");
        CompareProfile saved;
        using (var store = new CompareProfileStore(_temp.Paths))
        {
            saved = await store.SaveAsync(profile, Token);
        }

        using var reloaded = new CompareProfileStore(_temp.Paths);
        await reloaded.LoadAsync(Token);

        var loaded = Assert.Single(reloaded.Profiles);
        Assert.Equal("Nightly", loaded.Name);
        Assert.Equal(saved.Id, loaded.Id);
        Assert.Equal(profile.Source, loaded.Source);
        Assert.Equal(profile.Target, loaded.Target);
        Assert.Equal(profile.Options, loaded.Options);
        Assert.Equal(DataCompareScope.ChosenTables, loaded.Scope);
        var users = loaded.Tables[0];
        Assert.Equal(["email"], users.Scope.KeyColumns);
        Assert.Equal(["updated_at"], users.Scope.ExcludedColumns);
        Assert.Equal("active", users.Scope.SourceFilter);
        Assert.False(users.Scope.UsesSameFilterForTarget);
        Assert.Equal(500, users.Scope.RowLimit);
        Assert.False(loaded.Tables[1].IsIncluded);
        Assert.Equal("orders_v2", loaded.Tables[1].Target);
        Assert.True(loaded.Tables[1].Scope.UsesSameFilterForTarget);
    }

    [Fact]
    public async Task SavingAgainReplacesByIdAndKeepsCreatedAt()
    {
        using var store = new CompareProfileStore(_temp.Paths);
        var first = await store.SaveAsync(Profile("Nightly"), Token);

        var second = await store.SaveAsync(first with { Mode = CompareMode.Structure, CreatedAt = DateTimeOffset.MaxValue }, Token);

        Assert.Equal(first.CreatedAt, second.CreatedAt);
        Assert.Equal(CompareMode.Structure, Assert.Single(store.Profiles).Mode);
        Assert.Same(store.Profiles[0], store.FindByName("nightly"));
    }

    [Fact]
    public async Task ProfilesListByNameAndDelete()
    {
        using var store = new CompareProfileStore(_temp.Paths);
        var b = await store.SaveAsync(Profile("beta"), Token);
        await store.SaveAsync(Profile("Alpha"), Token);
        var changes = 0;
        store.Changed += (_, _) => changes++;

        Assert.Equal(["Alpha", "beta"], store.Profiles.Select(p => p.Name));
        Assert.True(await store.DeleteAsync(b.Id, Token));
        Assert.False(await store.DeleteAsync(b.Id, Token));
        Assert.Equal(["Alpha"], store.Profiles.Select(p => p.Name));
        Assert.Equal(1, changes);
    }

    [Fact]
    public async Task ANameIsRequired()
    {
        using var store = new CompareProfileStore(_temp.Paths);

        await Assert.ThrowsAsync<ArgumentException>(() => store.SaveAsync(Profile("  "), Token));
    }

    [Fact]
    public async Task AnOlderOrHandEditedFileStillLoads()
    {
        var source = Guid.NewGuid();
        var target = Guid.NewGuid();
        await File.WriteAllTextAsync(_temp.File(CompareProfileStore.FileName), $$"""
            {
              // written by hand
              "profiles": [
                { "name": "Minimal", "source": { "connectionId": "{{source}}" }, "target": { "connectionId": "{{target}}" },
                  "tables": [ { "source": "users" } ] },
                { "name": "No target", "source": { "connectionId": "{{source}}" } },
              ]
            }
            """, Token);
        using var store = new CompareProfileStore(_temp.Paths);

        await store.LoadAsync(Token);

        var profile = Assert.Single(store.Profiles);
        Assert.Equal(DataCompareScope.ChosenTables, profile.Scope);
        Assert.True(profile.Options.InsertMissingRows);
        Assert.True(profile.Options.UpdateChangedRows);
        var table = Assert.Single(profile.Tables);
        Assert.Equal("users", table.Target);
        Assert.True(table.IsIncluded);
        Assert.Empty(table.Scope.KeyColumns);
    }

    [Fact]
    public async Task SavingBeforeLoadingKeepsWhatIsOnDisk()
    {
        using (var first = new CompareProfileStore(_temp.Paths))
        {
            await first.SaveAsync(Profile("kept"), Token);
        }

        using var second = new CompareProfileStore(_temp.Paths);
        await second.SaveAsync(Profile("added"), Token);

        Assert.Equal(["added", "kept"], second.Profiles.Select(p => p.Name));
    }
}
