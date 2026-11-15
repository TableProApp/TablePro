namespace TablePro.Interop.Tests;

public sealed class SavedQueryTests : IDisposable
{
    private static readonly Guid Shop = Guid.Parse("6f0b6a4e-3a52-4c2f-9d1e-0c6a2b7f9e11");
    private static readonly Guid Other = Guid.Parse("1c2d3e4f-5a6b-4c7d-8e9f-a0b1c2d3e4f5");

    private readonly string _directory = Directory.CreateTempSubdirectory("tablepro-saved-").FullName;
    private readonly TableProCore _core;

    public SavedQueryTests()
    {
        _core = TableProCore.Create(new HostConfiguration("test", _directory), new MemorySecretStore());
    }

    public void Dispose()
    {
        _core.Dispose();
        try
        {
            Directory.Delete(_directory, recursive: true);
        }
        catch (IOException)
        {
            // The history database closes on the core's own threads, which can still hold it here on Windows.
        }
    }

    [Fact]
    public async Task AQueryIsSavedFiledInAFolderAndReplacedOnlyWhenAsked()
    {
        var cancellationToken = TestContext.Current.CancellationToken;
        using var history = await _core.OpenHistoryAsync(cancellationToken);
        using var queries = history.OpenSavedQueries();

        var reports = await queries.CreateFolderAsync(Shop, "Reports", null);
        var monthly = await queries.CreateFolderAsync(Shop, "Monthly", reports);
        var id = await queries.SaveAsync(Shop, "shop", "Orders", "SELECT * FROM orders", replace: false);
        await queries.SaveAsync(Other, "other", "Elsewhere", "SELECT 1", replace: false);
        await queries.MoveAsync(id!.Value, monthly);
        var taken = await queries.SaveAsync(Shop, "shop", "Orders", "SELECT 2", replace: false);
        var replaced = await queries.SaveAsync(Shop, "shop", "Orders", "SELECT 2", replace: true);
        var list = await queries.GetAsync(Shop, cancellationToken);

        Assert.Null(taken);
        Assert.Equal(id, replaced);
        var query = Assert.Single(list.Queries);
        Assert.Equal(("Orders", "SELECT 2", (long?)monthly, 0L), (query.Name, query.Sql, query.FolderId, query.Order));
        Assert.Null(query.Keyword);
        Assert.True(query.UpdatedAt > DateTimeOffset.UnixEpoch);
        Assert.Equal(2, list.Folders.Count);
        Assert.Equal(reports, Assert.Single(list.Folders, folder => folder.Id == monthly).ParentId);
    }

    [Fact]
    public async Task ARefusedNameOrKeywordThrowsItsCode()
    {
        using var history = await _core.OpenHistoryAsync(TestContext.Current.CancellationToken);
        using var queries = history.OpenSavedQueries();
        var one = await queries.SaveAsync(Shop, "shop", "One", "SELECT 1", replace: false);
        var two = await queries.SaveAsync(Shop, "shop", "Two", "SELECT 2", replace: false);
        await queries.SetKeywordAsync(one!.Value, "sel");
        await queries.CreateFolderAsync(Shop, "Reports", null);

        await queries.RenameAsync(one.Value, "First");
        await queries.SetSqlAsync(one.Value, "SELECT 11");
        var edited = Assert.Single((await queries.GetAsync(Shop, TestContext.Current.CancellationToken)).Queries, query => query.Id == one.Value);
        Assert.Equal(("First", "SELECT 11"), (edited.Name, edited.Sql));
        var name = await Assert.ThrowsAsync<TableProException>(() => queries.RenameAsync(two!.Value, "First"));
        var keyword = await Assert.ThrowsAsync<TableProException>(() => queries.SetKeywordAsync(two!.Value, "SEL"));
        var folder = await Assert.ThrowsAsync<TableProException>(() => queries.CreateFolderAsync(Shop, "reports", null));
        var empty = await Assert.ThrowsAsync<TableProException>(() => queries.SaveAsync(Shop, "shop", " ", "SELECT 3", replace: false));

        Assert.Equal("storage.name_taken", name.Error.Code);
        Assert.Equal("storage.keyword_taken", keyword.Error.Code);
        Assert.Equal("storage.folder_name_taken", folder.Error.Code);
        Assert.Equal("storage.empty_name", empty.Error.Code);
    }

    [Fact]
    public async Task DeletingAFolderGivesItsQueriesToTheTopAndAConnectionsDataGoesWithIt()
    {
        var cancellationToken = TestContext.Current.CancellationToken;
        using var history = await _core.OpenHistoryAsync(cancellationToken);
        using var queries = history.OpenSavedQueries();
        using var favourites = history.OpenFavourites();
        var folder = await queries.CreateFolderAsync(Shop, "Reports", null);
        var id = await queries.SaveAsync(Shop, "shop", "Mine", "SELECT 1", replace: false);
        await queries.MoveAsync(id!.Value, folder);
        await queries.SaveAsync(Other, "other", "Theirs", "SELECT 2", replace: false);
        await favourites.AddTableAsync(Shop, new FavouriteTable(null, "main", "orders"));

        await queries.DeleteFolderAsync(folder);
        var unfiled = await queries.GetAsync(Shop, cancellationToken);
        var removed = await queries.DeleteForConnectionAsync(Shop);

        Assert.Empty(unfiled.Folders);
        Assert.Null(Assert.Single(unfiled.Queries).FolderId);
        Assert.Equal(1, removed);
        Assert.Empty((await queries.GetAsync(Shop, cancellationToken)).Queries);
        Assert.Empty(await favourites.GetTablesAsync(Shop));
        Assert.Single((await queries.GetAsync(Other, cancellationToken)).Queries);
    }

    [Fact]
    public async Task FavouriteTablesAndDatabasesAreKeptPerConnection()
    {
        using var history = await _core.OpenHistoryAsync(TestContext.Current.CancellationToken);
        using var favourites = history.OpenFavourites();
        var orders = new FavouriteTable("shop", null, "orders");

        await favourites.AddTableAsync(Shop, orders);
        await favourites.AddTableAsync(Shop, orders);
        await favourites.SetDatabaseAsync(Shop, "shop", DatabaseEnvironment.Testing);
        await favourites.SetDatabaseAsync(Shop, "shop", DatabaseEnvironment.Production);
        var tables = await favourites.GetTablesAsync(Shop);
        var databases = await favourites.GetDatabasesAsync(Shop);
        await favourites.RemoveTableAsync(Shop, orders);
        await favourites.RemoveDatabaseAsync(Shop, "shop");

        Assert.Equal(orders, Assert.Single(tables));
        Assert.Equal(new FavouriteDatabase("shop", DatabaseEnvironment.Production), Assert.Single(databases));
        Assert.Empty(await favourites.GetTablesAsync(Shop));
        Assert.Empty(await favourites.GetDatabasesAsync(Shop));
        Assert.Empty(await favourites.GetTablesAsync(Other));
    }

    [Fact]
    public async Task APinnedRunComesFirstAndAnExportWritesTheRunsAskedFor()
    {
        var cancellationToken = TestContext.Current.CancellationToken;
        await using var session = await _core.OpenFileAsync(
            new FileOpenOptions(Path.Combine(_directory, "app.sqlite"), Create: true),
            cancellationToken);
        using var history = await _core.OpenHistoryAsync(cancellationToken);
        var at = DateTimeOffset.FromUnixTimeSeconds(1_700_000_000);
        var old = await history.RecordAsync(session, Ran("SELECT 'old'", at), cancellationToken);
        var recent = await history.RecordAsync(session, Ran("SELECT 'new'", at.AddMinutes(1)), cancellationToken);
        var file = Path.Combine(_directory, "history.sql");

        await history.SetPinnedAsync(old!.Value, pinned: true);
        var pinned = await history.SearchAsync(string.Empty, null, null, 50, cancellationToken);
        await history.SetPinnedAsync(old.Value, pinned: false);
        var unpinned = await history.SearchAsync(string.Empty, null, null, 50, cancellationToken);
        await history.ExportAsync([old.Value], HistoryExportFormat.Sql, file);

        Assert.Equal([(old, true), (recent, false)], pinned.Entries.Select(entry => ((long?)entry.Id, entry.Pinned)));
        Assert.Equal([recent, old], unpinned.Entries.Select(entry => (long?)entry.Id));
        var script = await File.ReadAllTextAsync(file, cancellationToken);
        Assert.Contains("SELECT 'old'", script, StringComparison.Ordinal);
        Assert.DoesNotContain("SELECT 'new'", script, StringComparison.Ordinal);
    }

    private static HistoryRun Ran(string sql, DateTimeOffset at) =>
        new(sql, at, null, null, HistoryOutcome.Succeeded.Instance);
}
