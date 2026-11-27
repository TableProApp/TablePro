using TablePro.App.Model.QuickSwitcher;

namespace TablePro.App.Model.Tests.QuickSwitcher;

public sealed class PaletteFrecencyStoreTests : IDisposable
{
    private readonly string _path = Path.Combine(Path.GetTempPath(), "tablepro-palette-" + Guid.NewGuid().ToString("N") + ".json");

    public void Dispose()
    {
        if (File.Exists(_path))
        {
            File.Delete(_path);
        }
    }

    [Fact]
    public void RecentIsOrderedByLatestAccess()
    {
        var store = new PaletteFrecencyStore(_path);
        var connection = Guid.NewGuid();
        var now = DateTimeOffset.UtcNow;
        store.RecordAccess(connection, "a", now.AddMinutes(-10));
        store.RecordAccess(connection, "b", now.AddMinutes(-1));
        store.RecordAccess(connection, "c", now.AddMinutes(-5));

        Assert.Equal(["b", "c", "a"], store.RecentItemIds(connection));
    }

    [Fact]
    public void ScoresRiseWithRecentAccess()
    {
        var store = new PaletteFrecencyStore(_path);
        var connection = Guid.NewGuid();
        var now = DateTimeOffset.UtcNow;
        store.RecordAccess(connection, "fresh", now);
        store.RecordAccess(connection, "stale", now.AddDays(-120));

        var scores = store.Scores(connection, now);
        Assert.True(scores["fresh"] > scores["stale"]);
        Assert.InRange(scores["fresh"], 0, 1);
    }

    [Fact]
    public void HistoryIsKeptPerConnection()
    {
        var store = new PaletteFrecencyStore(_path);
        var first = Guid.NewGuid();
        var second = Guid.NewGuid();
        store.RecordAccess(first, "a");
        store.RecordAccess(second, "b");

        Assert.Equal(["a"], store.RecentItemIds(first));
        Assert.Equal(["b"], store.RecentItemIds(second));
    }

    [Fact]
    public void ClearingDropsOneConnectionOnly()
    {
        var store = new PaletteFrecencyStore(_path);
        var first = Guid.NewGuid();
        var second = Guid.NewGuid();
        store.RecordAccess(first, "a");
        store.RecordAccess(second, "b");
        store.ClearHistory(first);

        Assert.Empty(store.RecentItemIds(first));
        Assert.Equal(["b"], store.RecentItemIds(second));
    }

    [Fact]
    public void AccessesPersistAcrossInstances()
    {
        var connection = Guid.NewGuid();
        new PaletteFrecencyStore(_path).RecordAccess(connection, "a");
        Assert.Equal(["a"], new PaletteFrecencyStore(_path).RecentItemIds(connection));
    }

    [Fact]
    public void AMissingFileReadsAsEmpty() =>
        Assert.Empty(new PaletteFrecencyStore(_path).RecentItemIds(Guid.NewGuid()));
}
