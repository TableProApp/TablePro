namespace TablePro.Interop.Tests;

public sealed class ConnectionCopyTests : IDisposable
{
    private readonly string _directory = Directory.CreateTempSubdirectory("tablepro-copies-").FullName;
    private readonly MemorySecretStore _secrets = new();
    private readonly TableProCore _core;

    public ConnectionCopyTests()
    {
        _core = TableProCore.Create(new HostConfiguration("test", Path.Combine(_directory, "one")), _secrets);
    }

    public void Dispose()
    {
        _core.Dispose();
        Directory.Delete(_directory, recursive: true);
    }

    private static SavedConnection Network(string name) =>
        new(null, name, "postgres", "db.example.com", 5432, "shop", "app", TlsSettings.Disabled);

    [Fact]
    public async Task ACopyLandsAfterItsOriginalWithItsOwnIdAndTheSamePassword()
    {
        var library = _core.Library;
        var shop = await library.SaveAsync(Network("Shop"), new ConnectionSecrets(DatabasePassword: "hunter2"));
        var after = await library.SaveAsync(Network("After"), ConnectionSecrets.None);
        await library.SetFavoriteAsync(shop.Id!.Value, true);

        var copy = await library.DuplicateAsync(shop.Id.Value, "Shop (Copy)");
        var snapshot = await library.GetSnapshotAsync();
        await library.DeleteAsync(shop.Id.Value);

        Assert.NotEqual(shop.Id, copy.Id);
        Assert.Equal("Shop (Copy)", copy.Name);
        Assert.Equal(("db.example.com", 5432, "app"), (copy.Host, copy.Port, copy.UserName));
        Assert.Null(copy.LastOpened);
        Assert.Equal([shop.Id, copy.Id, after.Id], snapshot.Connections.Select(connection => connection.Id));
        Assert.Equal([shop.Id.Value], snapshot.Favorites);
        Assert.Equal("hunter2", _secrets.Load(copy.Id!.Value, SecretKind.DatabasePassword));
    }

    [Fact]
    public async Task AnExportedFileHoldsEveryConnectionAndNoPassword()
    {
        var library = _core.Library;
        await library.SaveAsync(Network("Shop"), new ConnectionSecrets(DatabasePassword: "hunter2"));
        await library.SaveAsync(Network("Warehouse"), ConnectionSecrets.None);
        var file = Path.Combine(_directory, "connections.json");

        var count = await library.ExportAsync(file);
        var text = await File.ReadAllTextAsync(file, TestContext.Current.CancellationToken);
        using var elsewhere = TableProCore.Create(new HostConfiguration("test", Path.Combine(_directory, "two")), new MemorySecretStore());
        var imported = await elsewhere.Library.ImportAsync(file);

        Assert.Equal(2, count);
        Assert.Contains("Warehouse", text, StringComparison.Ordinal);
        Assert.DoesNotContain("hunter2", text, StringComparison.Ordinal);
        Assert.Equal(2, imported.Added);
        var unnamed = await Assert.ThrowsAsync<TableProException>(() => library.DuplicateAsync(Guid.NewGuid(), " "));
        Assert.Equal("library.name_required", unnamed.Error.Code);
    }
}
