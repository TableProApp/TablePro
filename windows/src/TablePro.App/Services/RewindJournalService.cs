using TablePro.Core.Editing;
using TablePro.Core.Rewind;
using TablePro.Core.Schema;
using TablePro.Storage;
using TablePro.Storage.Rewind;
using TablePro.Storage.Secrets;

namespace TablePro.App.Services;

/// <summary>
/// The app's one Data Rewind journal, and the hook a grid save calls after it commits. Static because the save runs
/// in a table tab, which reaches only its workspace context, and the journal belongs to the whole app.
/// </summary>
public static class RewindJournalService
{
    private static readonly Lazy<RewindJournalStore> Store = new(() => new RewindJournalStore(AppPaths.Default, new CredentialManagerSecretStore()));

    public static RewindJournalStore Journal => Store.Value;

    /// <summary>Whether saves are kept for restoring, the macOS "Keep saved changes for restoring" setting. On by default, as there.</summary>
    public static bool Enabled { get; set; } = true;

    /// <summary>
    /// Records a committed grid save. Call it after <c>SaveChangesAsync</c> succeeds and before the buffer is
    /// discarded: the rows are read from the buffer now, and written to the journal in the background so the save
    /// never waits on the disk.
    /// </summary>
    public static void Capture(ConnectionSession session, ObjectName table, TableEditBuffer buffer, IReadOnlyList<string> primaryKey)
    {
        ArgumentNullException.ThrowIfNull(session);
        if (!Enabled || buffer is null)
        {
            return;
        }

        RewindRecord? record;
        try
        {
            record = RewindCapture.FromBuffer(buffer, primaryKey ?? [], session.Profile.Id, session.Profile.Engine, session.Database.CurrentDatabase, table, DateTimeOffset.UtcNow);
        }
        catch (Exception ex) when (ex is not OutOfMemoryException)
        {
            CrashLog.Write("Data Rewind: capture a save", ex);
            return;
        }

        if (record is null)
        {
            return;
        }

        _ = Task.Run(async () =>
        {
            try
            {
                await Journal.RecordAsync(record);
            }
            catch (Exception ex) when (ex is not OutOfMemoryException)
            {
                // A save that already committed is never failed for its journal entry; it is just not restorable.
                CrashLog.Write("Data Rewind: keep a save", ex);
            }
        });
    }
}
