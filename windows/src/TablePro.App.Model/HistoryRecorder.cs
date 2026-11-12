using TablePro.Interop;

namespace TablePro.App.Model;

// Where a query tab keeps each run the user typed, once it ends.
public interface IHistoryRecorder
{
    Task RecordAsync(HistoryRun run);
}

// Recorded runs on the caller's context once the store kept the run, so a history pane can read it again.
public sealed class CoreHistoryRecorder(QueryHistory history, DatabaseSession session, Action? recorded = null)
    : IHistoryRecorder
{
    // No token: a close waits for the write rather than stopping it, since the session must outlive the call.
    public async Task RecordAsync(HistoryRun run)
    {
        ArgumentNullException.ThrowIfNull(run);
        long? id;
        try
        {
            id = await history.RecordAsync(session, run, CancellationToken.None).ConfigureAwait(true);
        }
        catch (TableProException)
        {
            // The run's result stands whether or not its history line was written.
            return;
        }

        if (id is not null)
        {
            recorded?.Invoke();
        }
    }
}
