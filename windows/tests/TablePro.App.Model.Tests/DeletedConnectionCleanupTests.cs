using TablePro.Interop;

namespace TablePro.App.Model.Tests;

public sealed class DeletedConnectionCleanupTests
{
    private static readonly Guid Shop = Guid.NewGuid();

    private static Task Fails(Guid id) =>
        Task.FromException(new TableProException(new CoreError("storage.io", ["storage.io"], "storage.io", null, null)));

    [Fact]
    public async Task SavedQueriesAlwaysGoAndTheHistoryOnlyWhenAsked()
    {
        List<string> ran = [];
        Task Saved(Guid id)
        {
            ran.Add($"saved {id == Shop}");
            return Task.CompletedTask;
        }

        Task History(Guid id)
        {
            ran.Add($"history {id == Shop}");
            return Task.CompletedTask;
        }

        var cleanup = new DeletedConnectionCleanup();
        await cleanup.PurgeAsync(Shop, deleteHistory: false, Saved, History);
        await cleanup.PurgeAsync(Shop, deleteHistory: true, Saved, History);

        Assert.Equal(["saved True", "saved True", "history True"], ran);
        Assert.True(cleanup.IsClean);
    }

    [Fact]
    public async Task AStoreThatDidNotOpenIsCountedNotSkipped()
    {
        var cleanup = new DeletedConnectionCleanup();

        await cleanup.PurgeAsync(Shop, deleteHistory: false, null, null);
        await cleanup.PurgeAsync(Guid.NewGuid(), deleteHistory: true, null, null);

        Assert.False(cleanup.IsClean);
        Assert.Equal((2, 1), (cleanup.SavedQueriesKept, cleanup.HistoryKept));
    }

    [Fact]
    public async Task AFailedStepIsCountedAndTheNextStepStillRuns()
    {
        var history = 0;
        var cleanup = new DeletedConnectionCleanup();

        await cleanup.PurgeAsync(
            Shop,
            deleteHistory: true,
            Fails,
            _ =>
            {
                history++;
                return Task.CompletedTask;
            });
        await cleanup.PurgeAsync(Shop, deleteHistory: true, _ => Task.CompletedTask, Fails);

        Assert.Equal(1, history);
        Assert.Equal((1, 1), (cleanup.SavedQueriesKept, cleanup.HistoryKept));
    }
}
