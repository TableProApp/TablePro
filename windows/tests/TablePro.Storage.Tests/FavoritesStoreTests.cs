using TablePro.Storage.Favorites;

namespace TablePro.Storage.Tests;

public sealed class FavoritesStoreTests : IDisposable
{
    private readonly TempDirectory _temp = new();

    private static CancellationToken Token => TestContext.Current.CancellationToken;

    public void Dispose() => _temp.Dispose();

    [Fact]
    public async Task FavoritesAndFoldersLoadBack()
    {
        var folder = new SqlFavoriteFolder { Name = "Reports" };
        var favorite = new SqlFavorite { Name = "Active users", Query = "SELECT * FROM users WHERE active", Keyword = " au ", FolderId = folder.Id };
        SqlFavorite saved;
        using (var store = new FavoritesStore(_temp.Paths))
        {
            await store.UpsertFolderAsync(folder, Token);
            saved = await store.UpsertFavoriteAsync(favorite, Token);
        }

        using var reloaded = new FavoritesStore(_temp.Paths);
        await reloaded.LoadAsync(Token);

        Assert.Equal("au", saved.Keyword);
        Assert.Equal(saved, Assert.Single(reloaded.Favorites));
        Assert.Equal(folder.Id, Assert.Single(reloaded.Folders).Id);
    }

    [Fact]
    public async Task UpdatingKeepsCreatedAtAndMovesUpdatedAt()
    {
        using var store = new FavoritesStore(_temp.Paths);
        var created = new DateTimeOffset(2026, 1, 1, 0, 0, 0, TimeSpan.Zero);
        var first = await store.UpsertFavoriteAsync(new SqlFavorite { Name = "q", Query = "SELECT 1", CreatedAt = created, UpdatedAt = created }, Token);

        var second = await store.UpsertFavoriteAsync(first with { Query = "SELECT 2", CreatedAt = DateTimeOffset.UtcNow }, Token);

        Assert.Equal(created, second.CreatedAt);
        Assert.True(second.UpdatedAt > created);
        Assert.Equal("SELECT 2", Assert.Single(store.Favorites).Query);
    }

    [Fact]
    public async Task KeywordLookupPrefersTheConnectionsOwnFavorite()
    {
        using var store = new FavoritesStore(_temp.Paths);
        var connection = Guid.NewGuid();
        var global = await store.UpsertFavoriteAsync(new SqlFavorite { Name = "global", Query = "SELECT 'global'", Keyword = "top" }, Token);
        var scoped = await store.UpsertFavoriteAsync(new SqlFavorite { Name = "scoped", Query = "SELECT 'scoped'", Keyword = "TOP", ConnectionId = connection }, Token);

        Assert.Equal(scoped.Id, store.FindByKeyword("top", connection)!.Id);
        Assert.Equal(global.Id, store.FindByKeyword("top", Guid.NewGuid())!.Id);
        Assert.Equal(global.Id, store.FindByKeyword("Top", null)!.Id);
        Assert.Null(store.FindByKeyword("missing", connection));

        var visible = store.GetVisible(Guid.NewGuid());
        Assert.Equal(global.Id, Assert.Single(visible.Favorites).Id);
        Assert.Equal(2, store.GetVisible(connection).Favorites.Count);
    }

    [Fact]
    public async Task ClashingOrMalformedKeywordsAreRejected()
    {
        using var store = new FavoritesStore(_temp.Paths);
        var existing = await store.UpsertFavoriteAsync(new SqlFavorite { Name = "a", Query = "SELECT 1", Keyword = "sel" }, Token);

        Assert.Equal(KeywordProblem.AlreadyUsed, store.ValidateKeyword("SEL", null));
        Assert.Equal(KeywordProblem.None, store.ValidateKeyword("sel", null, existing.Id));
        Assert.Equal(KeywordProblem.None, store.ValidateKeyword("sel", Guid.NewGuid()));
        Assert.Equal(KeywordProblem.ContainsWhitespace, store.ValidateKeyword("two words", null));
        Assert.Equal(KeywordProblem.TooLong, store.ValidateKeyword(new string('k', FavoritesStore.MaxKeywordLength + 1), null));

        await Assert.ThrowsAsync<ArgumentException>(() => store.UpsertFavoriteAsync(new SqlFavorite { Name = "b", Query = "SELECT 2", Keyword = "sel" }, Token));
        Assert.Single(store.Favorites);
    }

    [Fact]
    public async Task DeletingAFolderEitherLiftsOrRemovesItsContents()
    {
        using var store = new FavoritesStore(_temp.Paths);
        var root = await store.UpsertFolderAsync(new SqlFavoriteFolder { Name = "root" }, Token);
        var middle = await store.UpsertFolderAsync(new SqlFavoriteFolder { Name = "middle", ParentId = root.Id }, Token);
        var leaf = await store.UpsertFolderAsync(new SqlFavoriteFolder { Name = "leaf", ParentId = middle.Id }, Token);
        var inMiddle = await store.UpsertFavoriteAsync(new SqlFavorite { Name = "m", Query = "SELECT 1", FolderId = middle.Id }, Token);
        var inLeaf = await store.UpsertFavoriteAsync(new SqlFavorite { Name = "l", Query = "SELECT 2", FolderId = leaf.Id }, Token);

        await Assert.ThrowsAsync<InvalidOperationException>(() => store.UpsertFolderAsync(root with { ParentId = leaf.Id }, Token));

        Assert.True(await store.DeleteFolderAsync(middle.Id, cancellationToken: Token));
        Assert.Equal(root.Id, store.Favorites.Single(f => f.Id == inMiddle.Id).FolderId);
        Assert.Equal(root.Id, store.Folders.Single(f => f.Id == leaf.Id).ParentId);

        Assert.True(await store.DeleteFolderAsync(root.Id, deleteContents: true, Token));
        Assert.Empty(store.Folders);
        Assert.Empty(store.Favorites);
        Assert.DoesNotContain(store.Favorites, f => f.Id == inLeaf.Id);
    }

    [Theory]
    [InlineData("SELECT * FROM users", "SELECT * FROM users")]
    [InlineData("-- report\n\n  SELECT id\nFROM t", "SELECT id")]
    [InlineData("   ", "Untitled query")]
    public void NamesComeFromTheFirstStatementLine(string query, string expected) =>
        Assert.Equal(expected, SqlFavorite.NameFromQuery(query));
}
