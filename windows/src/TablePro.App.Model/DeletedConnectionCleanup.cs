using TablePro.Interop;

namespace TablePro.App.Model;

// What stayed on the PC after connections were deleted, counted in connections, for the page to say so.
public sealed class DeletedConnectionCleanup
{
    public int SavedQueriesKept { get; private set; }

    public int HistoryKept { get; private set; }

    public bool IsClean => SavedQueriesKept == 0 && HistoryKept == 0;

    // A null step means its store did not open. Saved queries always go; history only when the user asked.
    public async Task PurgeAsync(
        Guid connectionId,
        bool deleteHistory,
        Func<Guid, Task>? forgetSavedQueries,
        Func<Guid, Task>? forgetHistory)
    {
        if (!await RanAsync(forgetSavedQueries, connectionId).ConfigureAwait(true))
        {
            SavedQueriesKept++;
        }

        if (deleteHistory && !await RanAsync(forgetHistory, connectionId).ConfigureAwait(true))
        {
            HistoryKept++;
        }
    }

    private static async Task<bool> RanAsync(Func<Guid, Task>? step, Guid connectionId)
    {
        if (step is null)
        {
            return false;
        }

        try
        {
            await step(connectionId).ConfigureAwait(true);
            return true;
        }
        catch (TableProException)
        {
            return false;
        }
    }
}
