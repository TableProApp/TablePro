using System.Collections.ObjectModel;
using System.Globalization;
using CommunityToolkit.Mvvm.ComponentModel;
using TablePro.App.Services;
using TablePro.Core.Editing;
using TablePro.Core.Results;
using TablePro.Core.Rewind;
using TablePro.Core.Schema;
using TablePro.Core.Sql;
using TablePro.Storage.Rewind;

namespace TablePro.App.ViewModels;

/// <summary>
/// Data Rewind for one workspace: the saves the journal kept for this connection, and restoring one of them with
/// reviewed statements. A restore is an ordinary write: Safe Mode and a read-only connection govern it, it lands in
/// history, and it is journaled itself so it can be undone in turn.
/// </summary>
public sealed partial class RewindViewModel : ObservableObject
{
    private readonly WorkspaceContext _context;
    private readonly RewindJournalStore _journal;
    private readonly Func<ObjectName?> _currentTable;

    /// <param name="context">The workspace whose connection the saves belong to.</param>
    /// <param name="journal">The app's journal, <see cref="RewindJournalService.Journal"/>.</param>
    /// <param name="currentTable">The table of the selected tab, which "This table only" narrows the list to.</param>
    public RewindViewModel(WorkspaceContext context, RewindJournalStore journal, Func<ObjectName?> currentTable)
    {
        ArgumentNullException.ThrowIfNull(context);
        ArgumentNullException.ThrowIfNull(journal);
        _context = context;
        _journal = journal;
        _currentTable = currentTable;
    }

    /// <summary>Raised after a restore committed, with the table it wrote, so an open tab can reload.</summary>
    public event EventHandler<ObjectName>? Restored;

    public ObservableCollection<RewindJournalEntry> Entries { get; } = [];

    [ObservableProperty]
    public partial bool ThisTableOnly { get; set; }

    [ObservableProperty]
    public partial string? StatusText { get; set; }

    [ObservableProperty]
    public partial bool IsBusy { get; set; }

    public bool IsEnabled => RewindJournalService.Enabled;

    public async Task RefreshAsync()
    {
        try
        {
            var table = ThisTableOnly ? _currentTable() : null;
            var entries = await _journal.ListAsync(_context.Session.Profile.Id, table);
            Entries.Clear();
            foreach (var entry in entries)
            {
                Entries.Add(entry);
            }

            StatusText = entries.Count == 0
                ? (IsEnabled ? "No saved changes yet. Saves from the table grid appear here for 7 days." : "Keeping saved changes is turned off.")
                : null;
        }
        catch (Exception ex) when (ex is not OperationCanceledException)
        {
            CrashLog.Write("Data Rewind: list saves", ex);
            StatusText = ex.Message;
        }
    }

    /// <summary>Reviews and runs the restore of one save. True when it committed.</summary>
    public async Task<bool> RestoreAsync(RewindJournalEntry entry)
    {
        ArgumentNullException.ThrowIfNull(entry);
        var session = _context.Session;
        var dialogs = _context.Dialogs;
        if (session.Profile.IsReadOnly)
        {
            await dialogs.ShowErrorAsync("Read-only connection", "Safe Mode is Read-Only on this connection, so a save cannot be restored.");
            return false;
        }

        if (await _journal.GetAsync(entry.Id) is not { } record)
        {
            await dialogs.ShowErrorAsync("Cannot restore", "This save can no longer be read. Its record was cleared, or the key that protects saved changes is gone.");
            return false;
        }

        if (record.Database is { } database && !string.Equals(database, session.Database.CurrentDatabase, StringComparison.OrdinalIgnoreCase))
        {
            await dialogs.ShowErrorAsync("Different database", $"This save was made in {database}. Switch to it, then restore.");
            return false;
        }

        var plan = RewindPlanner.Plan(record);
        if (!plan.CanApply)
        {
            var reasons = plan.Refused.Select(o => o.Refusal).OfType<RewindRefusal>().Distinct().Select(RewindOperation.Explain);
            await dialogs.ShowErrorAsync("Nothing can be restored", string.Join("\n", reasons.DefaultIfEmpty("The save holds no row that can be put back.")));
            return false;
        }

        var preview = plan.Preview(session.Database);
        var lines = new List<string>(preview.Count + 2);
        var comment = session.Dialect.LineComment;
        lines.Add($"{comment} If any of these rows changed since the save, nothing is restored.");
        if (plan.Refused.Count > 0)
        {
            lines.Add(string.Create(CultureInfo.CurrentCulture, $"{comment} {plan.Refused.Count:N0} rows are skipped: ") + string.Join(" ", plan.Refused.Select(o => o.Refusal).OfType<RewindRefusal>().Distinct().Select(RewindOperation.Explain)));
        }

        lines.AddRange(preview);
        if (!await dialogs.ReviewSqlAsync($"Restore {record.Table.Name} to before the save", lines, "Restore"))
        {
            return false;
        }

        IsBusy = true;
        var started = DateTime.UtcNow;
        try
        {
            await session.Database.SaveChangesAsync(record.Table, plan.Changes, CancellationToken.None);
        }
        catch (RowCountMismatchException)
        {
            await dialogs.ShowErrorAsync("Nothing was restored", "A row changed or disappeared since this save, so restoring it would overwrite someone else's work. Nothing was changed.");
            return false;
        }
        catch (Exception ex) when (ex is not OperationCanceledException)
        {
            await dialogs.ShowErrorAsync("Nothing was restored", ex.Message);
            return false;
        }
        finally
        {
            IsBusy = false;
        }

        foreach (var statement in preview)
        {
            _context.History.Record(session.Profile, session.Database.CurrentDatabase, new StatementResult(statement, [], 1, DateTime.UtcNow - started), StatementKind.Write, "rewind");
        }

        var now = DateTimeOffset.UtcNow;
        try
        {
            await _journal.MarkRestoredAsync(record.Id, now);
            if (RewindJournalService.Enabled)
            {
                await _journal.RecordAsync(plan.InverseRecord(now));
            }
        }
        catch (Exception ex) when (ex is not OperationCanceledException)
        {
            CrashLog.Write("Data Rewind: journal a restore", ex);
        }

        _context.Notify(string.Create(CultureInfo.CurrentCulture, $"Restored {plan.Steps.Count:N0} rows in {record.Table.Name}."));
        Restored?.Invoke(this, record.Table);
        await RefreshAsync();
        return true;
    }

    public async Task ClearAsync()
    {
        if (!await _context.Dialogs.ConfirmAsync("Clear saved changes?", "Saves already committed stay committed. You will not be able to restore their previous values.", "Clear", destructive: true))
        {
            return;
        }

        await _journal.ClearAsync();
        await RefreshAsync();
    }

    partial void OnThisTableOnlyChanged(bool value) => _ = RefreshAsync();
}
