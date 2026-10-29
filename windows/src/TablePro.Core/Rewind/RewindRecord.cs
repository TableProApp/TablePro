using TablePro.Core.Connections;
using TablePro.Core.Localization;
using TablePro.Core.Schema;

namespace TablePro.Core.Rewind;

public enum RewindOperationKind : byte
{
    Insert,
    Update,
    Delete,
}

/// <summary>
/// Why a saved row cannot be taken back. Each is a case where the app does not know enough to restore the row
/// exactly, and refusing is better than writing something close that the user would trust.
/// </summary>
public enum RewindRefusal : byte
{
    /// <summary>The table has no primary key, so the old row cannot name one row.</summary>
    NoPrimaryKey = 1,

    /// <summary>The row was inserted with its key left to the server, which the grid never read back.</summary>
    ServerAssignedKey,

    /// <summary>A value was larger than the journal keeps, so it was never stored.</summary>
    ValueTooLarge,
}

/// <summary>
/// One row a save wrote: the row before (<see cref="Before"/>, absent for an insert) and after (<see cref="After"/>,
/// absent for a delete), laid out as <see cref="RewindRecord.Columns"/>.
/// </summary>
public sealed record RewindOperation(
    RewindOperationKind Kind,
    object?[]? Before,
    object?[]? After,
    IReadOnlyList<string> Written,
    RewindRefusal? Refusal = null)
{
    public bool IsReversible => Refusal is null;

    public static string Explain(RewindRefusal refusal) => refusal switch
    {
        RewindRefusal.NoPrimaryKey => CoreStrings.Get("Rewind/RefusalNoPrimaryKey"),
        RewindRefusal.ServerAssignedKey => CoreStrings.Get("Rewind/RefusalServerAssignedKey"),
        RewindRefusal.ValueTooLarge => CoreStrings.Get("Rewind/RefusalValueTooLarge"),
        _ => refusal.ToString(),
    };
}

/// <summary>One committed grid save, kept in the local journal so it can be taken back.</summary>
public sealed record RewindRecord(
    Guid Id,
    Guid ConnectionId,
    DatabaseEngine Engine,
    string? Database,
    ObjectName Table,
    DateTimeOffset CapturedAt,
    IReadOnlyList<string> Columns,
    IReadOnlyList<string> PrimaryKey,
    IReadOnlyList<RewindOperation> Operations)
{
    /// <summary>The record this one restored, when it is itself a rewind; undoing it redoes the original save.</summary>
    public Guid? Restores { get; init; }

    public int ReversibleCount => Operations.Count(o => o.IsReversible);

    public bool IsReversible => ReversibleCount > 0;

    /// <summary>How many rows the save edited, added and deleted.</summary>
    public RewindCounts Counts => RewindCounts.Of(Operations);

    /// <summary>"2 edited, 1 added", as the list of saves shows it, in the UI language.</summary>
    public string Summary => Counts.Describe();

    public int ColumnIndex(string column)
    {
        for (var i = 0; i < Columns.Count; i++)
        {
            if (string.Equals(Columns[i], column, StringComparison.OrdinalIgnoreCase))
            {
                return i;
            }
        }

        return -1;
    }
}

/// <summary>
/// What a save did, as counts. The journal keeps these rather than finished text, so the list of saves is worded in the
/// language the app runs in when it is shown, not the one it ran in when the save was made.
/// </summary>
public readonly record struct RewindCounts(int Edited, int Added, int Deleted)
{
    public static RewindCounts Of(IEnumerable<RewindOperation> operations)
    {
        ArgumentNullException.ThrowIfNull(operations);
        int edited = 0, added = 0, deleted = 0;
        foreach (var operation in operations)
        {
            switch (operation.Kind)
            {
                case RewindOperationKind.Update:
                    edited++;
                    break;
                case RewindOperationKind.Insert:
                    added++;
                    break;
                case RewindOperationKind.Delete:
                    deleted++;
                    break;
            }
        }

        return new(edited, added, deleted);
    }

    /// <summary>"2 edited, 1 added", leaving out the kinds the save did not touch.</summary>
    public string Describe()
    {
        var parts = new List<string>(3);
        if (Edited > 0)
        {
            parts.Add(CoreStrings.Plural("Rewind/Edited", Edited));
        }

        if (Added > 0)
        {
            parts.Add(CoreStrings.Plural("Rewind/Added", Added));
        }

        if (Deleted > 0)
        {
            parts.Add(CoreStrings.Plural("Rewind/Deleted", Deleted));
        }

        return string.Join(CoreStrings.Get("Rewind/SummarySeparator"), parts);
    }
}
