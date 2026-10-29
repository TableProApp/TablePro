using System.Collections.ObjectModel;
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
                ? (IsEnabled ? Strings.Get("Rewind/EmptyEnabled") : Strings.Get("Rewind/EmptyDisabled"))
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
            await dialogs.ShowErrorAsync(Strings.Get("Rewind/ReadOnlyTitle"), Strings.Get("Rewind/ReadOnlyMessage"));
            return false;
        }

        if (await _journal.GetAsync(entry.Id) is not { } record)
        {
            await dialogs.ShowErrorAsync(Strings.Get("Rewind/CannotRestoreTitle"), Strings.Get("Rewind/CannotRestoreMessage"));
            return false;
        }

        if (record.Database is { } database && !string.Equals(database, session.Database.CurrentDatabase, StringComparison.OrdinalIgnoreCase))
        {
            await dialogs.ShowErrorAsync(Strings.Get("Rewind/DifferentDatabaseTitle"), Strings.Format("Rewind/DifferentDatabaseMessage", database));
            return false;
        }

        var plan = RewindPlanner.Plan(record);
        if (!plan.CanApply)
        {
            var reasons = plan.Refused.Select(o => o.Refusal).OfType<RewindRefusal>().Distinct().Select(ToolsNames.RewindRefusalText);
            await dialogs.ShowErrorAsync(Strings.Get("Rewind/NothingCanBeRestoredTitle"), string.Join("\n", reasons.DefaultIfEmpty(Strings.Get("Rewind/NoRowToPutBack"))));
            return false;
        }

        var preview = plan.Preview(session.Database);
        var lines = new List<string>(preview.Count + 2);
        var comment = session.Dialect.LineComment;
        lines.Add(Strings.Format("Rewind/ReviewNothingIfChanged", comment));
        if (plan.Refused.Count > 0)
        {
            var skipped = string.Join(" ", plan.Refused.Select(o => o.Refusal).OfType<RewindRefusal>().Distinct().Select(ToolsNames.RewindRefusalText));
            lines.Add(Strings.Plural("Rewind/ReviewRowsSkipped", plan.Refused.Count, comment, skipped));
        }

        lines.AddRange(preview);
        if (!await dialogs.ReviewSqlAsync(Strings.Format("Rewind/RestoreReviewTitle", record.Table.Name), lines, Strings.Get("Rewind/RestoreButton")))
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
            await dialogs.ShowErrorAsync(Strings.Get("Rewind/NothingRestoredTitle"), Strings.Get("Rewind/RowChangedMessage"));
            return false;
        }
        catch (Exception ex) when (ex is not OperationCanceledException)
        {
            await dialogs.ShowErrorAsync(Strings.Get("Rewind/NothingRestoredTitle"), ex.Message);
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

        _context.Notify(Strings.Plural("Rewind/Restored", plan.Steps.Count, record.Table.Name));
        Restored?.Invoke(this, record.Table);
        await RefreshAsync();
        return true;
    }

    public async Task ClearAsync()
    {
        if (!await _context.Dialogs.ConfirmAsync(Strings.Get("Rewind/ClearConfirmTitle"), Strings.Get("Rewind/ClearConfirmMessage"), Strings.Get("Common/Clear"), destructive: true))
        {
            return;
        }

        await _journal.ClearAsync();
        await RefreshAsync();
    }

    partial void OnThisTableOnlyChanged(bool value) => _ = RefreshAsync();
}
