namespace TablePro.Interop.Tests;

public sealed class ConnectionLibraryTests : IDisposable
{
    private readonly string _directory = Directory.CreateTempSubdirectory("tablepro-library-").FullName;
    private readonly MemorySecretStore _secrets = new();
    private readonly TableProCore _core;

    public ConnectionLibraryTests()
    {
        _core = TableProCore.Create(new HostConfiguration("test", _directory), _secrets);
    }

    public void Dispose()
    {
        _core.Dispose();
        Directory.Delete(_directory, recursive: true);
    }

    private static SavedConnection Network(string name) =>
        new(null, name, "postgres", "db.example.com", 5432, "shop", "app", TlsSettings.Disabled);

    [Fact]
    public async Task AConnectionComesBackInItsNestedGroupAndAmongTheFavorites()
    {
        var library = _core.Library;

        var work = await library.CreateGroupAsync("Work", null);
        var staging = await library.CreateGroupAsync("Staging", work.Id);
        var saved = await library.SaveAsync(Network("shop") with { GroupId = staging.Id }, ConnectionSecrets.None);
        await library.SetFavoriteAsync(saved.Id!.Value, true);
        var snapshot = await library.GetSnapshotAsync();

        Assert.Equal(["Work", "Staging"], snapshot.Groups.Select(group => group.Name));
        Assert.Equal(work.Id, snapshot.Groups[1].ParentId);
        var connection = Assert.Single(snapshot.Connections);
        Assert.Equal(staging.Id, connection.GroupId);
        Assert.Equal("db.example.com", connection.Host);
        Assert.Equal(5432, connection.Port);
        Assert.Equal([saved.Id.Value], snapshot.Favorites);
    }

    [Fact]
    public async Task SavingAgainKeepsTheIdAndAPasswordLeavesWithItsConnection()
    {
        var library = _core.Library;

        var first = await library.SaveAsync(Network("shop"), new ConnectionSecrets(DatabasePassword: "hunter2"));
        var id = first.Id!.Value;
        var second = await library.SaveAsync(first with { Name = "shop (prod)", SafeMode = SafeMode.ReadOnly }, ConnectionSecrets.None);
        var stored = _secrets.Load(id, SecretKind.DatabasePassword);
        await library.DeleteAsync(id);

        Assert.Equal(id, second.Id);
        Assert.Equal("shop (prod)", second.Name);
        Assert.Equal(SafeMode.ReadOnly, second.SafeMode);
        Assert.Equal("hunter2", stored);
        Assert.Null(_secrets.Load(id, SecretKind.DatabasePassword));
        Assert.Empty((await library.GetSnapshotAsync()).Connections);
    }

    [Fact]
    public async Task ASavedSqliteFileConnectsAndBecomesRecent()
    {
        var cancellationToken = TestContext.Current.CancellationToken;
        await using var database = await SqliteDatabase.CreateAsync();
        var library = _core.Library;
        var saved = await library.SaveAsync(
            new SavedConnection(null, "app", "sqlite", string.Empty, 0, database.Path, string.Empty, TlsSettings.Disabled),
            ConnectionSecrets.None);

        await _core.TestConnectionAsync(saved, ConnectionSecrets.None, cancellationToken);
        await using var session = await _core.ConnectAsync(saved.Id!.Value, cancellationToken: cancellationToken);
        var objects = await session.GetObjectsAsync(ObjectScope.DefaultSchema, cancellationToken);
        var browse = await session.GetTableQueryAsync(new TableName(null, "people"), null, 100, cancellationToken);
        var snapshot = await library.GetSnapshotAsync();

        Assert.Contains(objects, entry => entry.Name == "people");
        Assert.Contains("FROM \"people\"", browse.Sql, StringComparison.Ordinal);
        Assert.Equal(3, browse.VisibleColumns);
        Assert.Equal([saved.Id.Value], snapshot.Recent);
        Assert.NotNull(snapshot.Connections[0].LastOpened);
    }

    [Fact]
    public async Task ALoginWithNoSavedPasswordFailsByCode()
    {
        var saved = await _core.Library.SaveAsync(Network("shop") with { Host = "127.0.0.1", Port = 1 }, ConnectionSecrets.None);

        var error = await Assert.ThrowsAsync<TableProException>(
            () => _core.ConnectAsync(saved.Id!.Value, cancellationToken: TestContext.Current.CancellationToken));

        Assert.Equal("keyring.secret_not_stored", error.Code);
    }

    [Fact]
    public void AConnectionUrlFillsTheFormFields()
    {
        var parsed = TableProCore.ParseConnectionUrl("postgresql://app:p%40ss@db.example.com:6543/shop?sslmode=require");

        Assert.Equal("postgres", parsed.EngineId);
        Assert.Equal("db.example.com", parsed.Host);
        Assert.Equal(6543, parsed.Port);
        Assert.Equal("app", parsed.UserName);
        Assert.Equal("p@ss", parsed.Password);
        Assert.Equal("shop", parsed.Database);
        Assert.Equal(TlsMode.Require, parsed.TlsMode);
        Assert.Equal(
            "url.unknown_scheme",
            Assert.Throws<TableProException>(() => TableProCore.ParseConnectionUrl("ftp://example.com")).Code);
    }

    [Fact]
    public void ACoreWithoutAStorageDirectoryHasNoLibrary()
    {
        using var core = TableProCore.Create(new HostConfiguration("test"), new MemorySecretStore());

        Assert.Equal("ffi.no_storage", Assert.Throws<TableProException>(() => core.Library).Code);
    }
}
