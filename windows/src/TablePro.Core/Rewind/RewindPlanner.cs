using System.Globalization;
using TablePro.Core.Drivers;
using TablePro.Core.Editing;
using TablePro.Core.Sql;

namespace TablePro.Core.Rewind;

/// <summary>One row a rewind puts back, and the change that does it.</summary>
public sealed record RewindStep(RewindOperation Operation, RowChange Change, string Key, string Action);

/// <summary>
/// What restoring a save would run, decided before anything is written. Skipped rows are those the record itself
/// refuses; whether a row was changed since the save is decided by the write, which rolls everything back.
/// </summary>
public sealed class RewindPlan
{
    internal RewindPlan(RewindRecord record, IReadOnlyList<RewindStep> steps, IReadOnlyList<RewindOperation> refused)
    {
        Record = record;
        Steps = steps;
        Refused = refused;
    }

    public RewindRecord Record { get; }

    /// <summary>The inverse changes, newest first, so a row that freed a value another row took is restored in an order that does not collide.</summary>
    public IReadOnlyList<RewindStep> Steps { get; }

    public IReadOnlyList<RewindOperation> Refused { get; }

    public bool CanApply => Steps.Count > 0;

    public IReadOnlyList<RowChange> Changes => [.. Steps.Select(s => s.Change)];

    public IReadOnlyList<string> Preview(IDatabaseSession session)
    {
        ArgumentNullException.ThrowIfNull(session);
        return session is IChangePreviewProvider custom ? custom.PreviewChanges(Record.Table, Changes) : Preview(session.Dialect);
    }

    public IReadOnlyList<string> Preview(SqlDialect dialect) => [.. Steps.Select(s => ChangeSqlBuilder.Preview(dialect, Record.Table, s.Change))];

    /// <summary>
    /// The restore recorded as the save it is, with each row's images the other way round, so undoing a rewind is
    /// another ordinary rewind rather than a special case.
    /// </summary>
    public RewindRecord InverseRecord(DateTimeOffset capturedAt)
    {
        // In the order the restore ran, as a captured save is, so planning this record reverses it again.
        var operations = Steps
            .Select(s => s.Operation)
            .Select(o => o.Kind switch
            {
                RewindOperationKind.Update => new RewindOperation(RewindOperationKind.Update, o.After, o.Before, o.Written),
                RewindOperationKind.Delete => new RewindOperation(RewindOperationKind.Insert, null, o.Before, o.Written),
                _ => new RewindOperation(RewindOperationKind.Delete, o.After, null, o.Written),
            })
            .ToArray();
        return Record with { Id = Guid.NewGuid(), CapturedAt = capturedAt, Operations = operations, Restores = Record.Id };
    }
}

/// <summary>
/// Builds the inverse of a recorded save. Every keyed step carries the values the save wrote in its WHERE clause, so
/// a row someone changed since matches nothing, the session's one-row check fails, and the whole restore rolls back
/// instead of overwriting their work.
/// </summary>
/// <remarks>
/// macOS reads the rows first and plans row by row. The Windows browse filter binds values as text, which not every
/// engine compares with a typed key, so the check here rides on the write itself, bound with the original values.
/// </remarks>
public static class RewindPlanner
{
    /// <summary>Text longer than this is left out of the conflict check, since some engines cannot compare a LOB with =.</summary>
    private const int MaxCheckedTextLength = 255;

    public static RewindPlan Plan(RewindRecord record)
    {
        ArgumentNullException.ThrowIfNull(record);
        var keyIndexes = record.PrimaryKey.Select(record.ColumnIndex).ToArray();
        var steps = new List<RewindStep>(record.Operations.Count);
        var refused = new List<RewindOperation>();

        for (var i = record.Operations.Count - 1; i >= 0; i--)
        {
            var operation = record.Operations[i];
            if (!operation.IsReversible || keyIndexes.Length == 0 || keyIndexes.Any(k => k < 0))
            {
                refused.Add(operation);
                continue;
            }

            switch (operation.Kind)
            {
                case RewindOperationKind.Update when operation.Before is { } before && operation.After is { } after:
                {
                    var values = new Dictionary<string, object?>(StringComparer.Ordinal);
                    foreach (var column in operation.Written)
                    {
                        var index = record.ColumnIndex(column);
                        if (index >= 0)
                        {
                            values[record.Columns[index]] = before[index];
                        }
                    }

                    if (values.Count == 0)
                    {
                        continue;
                    }

                    var change = new RowUpdate(Guard(record, keyIndexes, after, operation.Written), values);
                    steps.Add(new RewindStep(operation, change, Describe(record, keyIndexes, after), "Restore previous values"));
                    break;
                }

                case RewindOperationKind.Delete when operation.Before is { } before:
                {
                    var values = new Dictionary<string, object?>(StringComparer.Ordinal);
                    foreach (var column in operation.Written)
                    {
                        var index = record.ColumnIndex(column);
                        if (index >= 0)
                        {
                            values[record.Columns[index]] = before[index];
                        }
                    }

                    steps.Add(new RewindStep(operation, new RowInsert(values), Describe(record, keyIndexes, before), "Put the row back"));
                    break;
                }

                case RewindOperationKind.Insert when operation.After is { } after:
                    steps.Add(new RewindStep(operation, new RowDelete(Guard(record, keyIndexes, after, operation.Written)), Describe(record, keyIndexes, after), "Remove the added row"));
                    break;

                default:
                    refused.Add(operation);
                    break;
            }
        }

        return new RewindPlan(record, steps, refused);
    }

    /// <summary>The key, plus every column the save wrote whose value can be matched exactly with =.</summary>
    private static Dictionary<string, object?> Guard(RewindRecord record, int[] keyIndexes, object?[] row, IReadOnlyList<string> written)
    {
        var guard = new Dictionary<string, object?>(keyIndexes.Length + written.Count, StringComparer.Ordinal);
        foreach (var index in keyIndexes)
        {
            guard[record.Columns[index]] = row[index];
        }

        foreach (var column in written)
        {
            var index = record.ColumnIndex(column);
            if (index >= 0 && !guard.ContainsKey(record.Columns[index]) && IsExactlyComparable(row[index]))
            {
                guard[record.Columns[index]] = row[index];
            }
        }

        return guard;
    }

    // A float can come back from the server a bit away from what was bound, and a LOB cannot be compared with = on
    // every engine, so those columns are left out of the check rather than making every restore fail.
    private static bool IsExactlyComparable(object? value) => value switch
    {
        null => true,
        double or float => false,
        string s => s.Length <= MaxCheckedTextLength,
        byte[] => false,
        _ => true,
    };

    private static string Describe(RewindRecord record, int[] keyIndexes, object?[] row) =>
        string.Join(", ", keyIndexes.Select(i => string.Create(CultureInfo.InvariantCulture, $"{record.Columns[i]}={Compare.CompareValues.Describe(row[i])}")));
}
