using TablePro.Core.Connections;
using TablePro.Core.Editing;
using TablePro.Core.Schema;

namespace TablePro.Core.Rewind;

/// <summary>
/// Reads what a grid save is about to commit, before the buffer is discarded: the old row for every update and
/// delete, and the new row for every update and insert.
/// </summary>
public static class RewindCapture
{
    /// <summary>A text value longer than this, or a binary one larger, is not kept; the row it is in cannot be rewound.</summary>
    public const int MaxValueLength = 1 << 20;

    /// <summary>
    /// The record of a save, in the order the save ran (deletes, updates, inserts), or null when the buffer holds no
    /// change. Call it after <see cref="Drivers.IDatabaseSession.SaveChangesAsync"/> succeeds and before the buffer
    /// is discarded.
    /// </summary>
    public static RewindRecord? FromBuffer(
        TableEditBuffer buffer,
        IReadOnlyList<string> primaryKey,
        Guid connectionId,
        DatabaseEngine engine,
        string? database,
        ObjectName table,
        DateTimeOffset capturedAt)
    {
        ArgumentNullException.ThrowIfNull(buffer);
        ArgumentNullException.ThrowIfNull(primaryKey);
        if (!buffer.HasChanges)
        {
            return null;
        }

        var baseline = buffer.Baseline;
        var columns = baseline.Columns.Select(c => c.Name).ToArray();
        var keyIndexes = primaryKey.Select(baseline.ColumnIndex).ToArray();
        RewindRefusal? tableRefusal = keyIndexes.Length == 0 || keyIndexes.Any(i => i < 0) ? RewindRefusal.NoPrimaryKey : null;

        var deletes = new List<RewindOperation>();
        var updates = new List<RewindOperation>();
        var inserts = new List<RewindOperation>();
        for (var row = 0; row < buffer.RowCount; row++)
        {
            switch (buffer.GetRowState(row))
            {
                case RowEditState.Deleted:
                    deletes.Add(Operation(RewindOperationKind.Delete, Copy(baseline.Rows[row]), null, columns, tableRefusal));
                    break;
                case RowEditState.Modified:
                    var written = new List<string>();
                    var after = new object?[columns.Length];
                    for (var c = 0; c < columns.Length; c++)
                    {
                        after[c] = buffer.GetValue(row, c);
                        if (buffer.IsCellModified(row, c))
                        {
                            written.Add(columns[c]);
                        }
                    }

                    updates.Add(Operation(RewindOperationKind.Update, Copy(baseline.Rows[row]), after, written, tableRefusal));
                    break;
                case RowEditState.Inserted:
                    var values = new object?[columns.Length];
                    var set = new List<string>();
                    for (var c = 0; c < columns.Length; c++)
                    {
                        values[c] = buffer.GetValue(row, c);

                        // The save leaves an empty cell out of the INSERT so the column takes its default, which the
                        // grid never read back; only what was sent is known.
                        if (values[c] is not null)
                        {
                            set.Add(columns[c]);
                        }
                    }

                    var refusal = tableRefusal ?? (keyIndexes.Any(i => values[i] is null) ? RewindRefusal.ServerAssignedKey : null);
                    inserts.Add(Operation(RewindOperationKind.Insert, null, values, set, refusal));
                    break;
            }
        }

        return new RewindRecord(Guid.NewGuid(), connectionId, engine, database, table, capturedAt, columns, [.. primaryKey], [.. deletes, .. updates, .. inserts]);
    }

    private static RewindOperation Operation(RewindOperationKind kind, object?[]? before, object?[]? after, IReadOnlyList<string> written, RewindRefusal? refusal)
    {
        // A refused row keeps no images: they could never be used, and they are production data on disk.
        if (refusal is null && (TooLarge(before) || TooLarge(after)))
        {
            refusal = RewindRefusal.ValueTooLarge;
        }

        return refusal is null
            ? new RewindOperation(kind, before, after, written)
            : new RewindOperation(kind, null, null, written, refusal);
    }

    private static bool TooLarge(object?[]? row)
    {
        if (row is null)
        {
            return false;
        }

        foreach (var value in row)
        {
            if (value is string { Length: > MaxValueLength } or byte[] { Length: > MaxValueLength })
            {
                return true;
            }
        }

        return false;
    }

    private static object?[] Copy(object?[] row) => (object?[])row.Clone();
}
