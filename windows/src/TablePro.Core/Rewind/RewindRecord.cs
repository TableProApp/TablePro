using System.Globalization;
using TablePro.Core.Connections;
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
        RewindRefusal.NoPrimaryKey => "The table has no primary key, so this row cannot be identified.",
        RewindRefusal.ServerAssignedKey => "The server chose this row's key.",
        RewindRefusal.ValueTooLarge => "A value was too large to keep.",
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

    /// <summary>"2 edited, 1 added", as the list of saves shows it.</summary>
    public string Summary
    {
        get
        {
            var updated = Operations.Count(o => o.Kind == RewindOperationKind.Update);
            var inserted = Operations.Count(o => o.Kind == RewindOperationKind.Insert);
            var deleted = Operations.Count(o => o.Kind == RewindOperationKind.Delete);
            var parts = new List<string>(3);
            if (updated > 0)
            {
                parts.Add(string.Create(CultureInfo.CurrentCulture, $"{updated:N0} edited"));
            }

            if (inserted > 0)
            {
                parts.Add(string.Create(CultureInfo.CurrentCulture, $"{inserted:N0} added"));
            }

            if (deleted > 0)
            {
                parts.Add(string.Create(CultureInfo.CurrentCulture, $"{deleted:N0} deleted"));
            }

            return string.Join(", ", parts);
        }
    }

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
