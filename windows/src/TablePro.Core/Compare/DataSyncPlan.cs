using TablePro.Core.Connections;
using TablePro.Core.Drivers;
using TablePro.Core.Editing;
using TablePro.Core.Schema;
using TablePro.Core.Sql;

namespace TablePro.Core.Compare;

public enum SyncStepKind : byte
{
    Insert,
    Update,
    Delete,
}

/// <summary>One statement of a sync: the change the target's session runs, and the row it is for.</summary>
public sealed record SyncStep(SyncStepKind Kind, RowChange Change, string Key, string KeyIdentity);

/// <summary>
/// The INSERT, UPDATE and DELETE statements that make the target's rows match the source's, built from a
/// comparison and reviewed before anything runs. Inserts run before updates before deletes, as on macOS.
/// </summary>
/// <remarks>
/// Each step is a <see cref="RowChange"/>, so values are bound as parameters by the target session exactly as a grid
/// save binds them, and every keyed step must touch one row or the whole transaction rolls back.
/// </remarks>
public sealed class DataSyncPlan
{
    private DataSyncPlan(ObjectName table, IReadOnlyList<SyncStep> steps, IReadOnlyList<string> warnings)
    {
        Table = table;
        Steps = steps;
        Warnings = warnings;
    }

    public ObjectName Table { get; }

    public IReadOnlyList<SyncStep> Steps { get; }

    /// <summary>What the user should know before applying, such as an identity column the target may refuse.</summary>
    public IReadOnlyList<string> Warnings { get; }

    public int InsertCount => Steps.Count(s => s.Kind == SyncStepKind.Insert);

    public int UpdateCount => Steps.Count(s => s.Kind == SyncStepKind.Update);

    public int DeleteCount => Steps.Count(s => s.Kind == SyncStepKind.Delete);

    public bool IsEmpty => Steps.Count == 0;

    public IReadOnlyList<RowChange> Changes => [.. Steps.Select(s => s.Change)];

    /// <param name="result">A finished comparison. A truncated one is refused, since its plan would cover only part of the differences.</param>
    /// <param name="options">Which kinds of difference to write.</param>
    /// <param name="excludedKeys">Row identities (<see cref="DataCompareSpec.KeyIdentity"/>) the user unticked.</param>
    public static DataSyncPlan Build(DataDiffResult result, DataCompareOptions options, IReadOnlySet<string>? excludedKeys = null)
    {
        ArgumentNullException.ThrowIfNull(result);
        ArgumentNullException.ThrowIfNull(options);
        if (result.IsTruncated)
        {
            throw new CompareException($"The comparison found {result.DifferenceCount:N0} differences, more than the {result.Differences.Count:N0} a sync can review. Narrow it with a filter or a row limit and compare again.");
        }

        var spec = result.Spec;
        var inserts = new List<SyncStep>();
        var updates = new List<SyncStep>();
        var deletes = new List<SyncStep>();
        foreach (var diff in result.Differences)
        {
            if (!options.Writes(diff.Kind))
            {
                continue;
            }

            var identity = spec.KeyIdentity(diff.KeyRow);
            if (excludedKeys?.Contains(identity) == true)
            {
                continue;
            }

            var key = spec.DescribeKey(diff.KeyRow);
            switch (diff.Kind)
            {
                case RowDiffKind.OnlyInSource:
                    inserts.Add(new SyncStep(SyncStepKind.Insert, new RowInsert(AllValues(spec, diff.Source!)), key, identity));
                    break;
                case RowDiffKind.Changed:
                    updates.Add(new SyncStep(SyncStepKind.Update, new RowUpdate(TargetKey(spec, diff.Target!), ChangedValues(spec, diff)), key, identity));
                    break;
                case RowDiffKind.OnlyInTarget:
                    deletes.Add(new SyncStep(SyncStepKind.Delete, new RowDelete(TargetKey(spec, diff.Target!)), key, identity));
                    break;
            }
        }

        var warnings = new List<string>();
        if (inserts.Count > 0 && spec.Columns.FirstOrDefault(c => c.TargetIsIdentity) is { } identityColumn)
        {
            warnings.Add($"{identityColumn.Target} is an identity column on the target. Engines such as SQL Server refuse an explicit value there, which rolls the sync back.");
        }

        if (deletes.Count > 0)
        {
            warnings.Add($"{deletes.Count:N0} rows will be deleted from {result.Spec.TargetTable} for good.");
        }

        if (result.StoppedAtRowLimit)
        {
            warnings.Add("The row limit cut the comparison short, so rows past it are left as they are.");
        }

        return new DataSyncPlan(spec.TargetTable, [.. inserts, .. updates, .. deletes], warnings);
    }

    /// <summary>The statements with their values written in, for the review sheet and the history.</summary>
    public IReadOnlyList<string> Preview(IDatabaseSession target)
    {
        ArgumentNullException.ThrowIfNull(target);
        var changes = Changes;
        return target is IChangePreviewProvider custom ? custom.PreviewChanges(Table, changes) : Preview(target.Dialect);
    }

    public IReadOnlyList<string> Preview(SqlDialect dialect) =>
        [.. Steps.Select(s => ChangeSqlBuilder.Preview(dialect, Table, s.Change))];

    private static Dictionary<string, object?> AllValues(DataCompareSpec spec, object?[] row)
    {
        var values = new Dictionary<string, object?>(spec.Columns.Count, StringComparer.Ordinal);
        for (var i = 0; i < spec.Columns.Count; i++)
        {
            // NULL is written as NULL rather than left out, so the target does not fill in its own default.
            values[spec.Columns[i].Target] = row[i];
        }

        return values;
    }

    private static Dictionary<string, object?> TargetKey(DataCompareSpec spec, object?[] row)
    {
        var key = new Dictionary<string, object?>(spec.KeyIndexes.Length, StringComparer.Ordinal);
        foreach (var index in spec.KeyIndexes)
        {
            key[spec.Columns[index].Target] = row[index];
        }

        return key;
    }

    // Only the columns that differ are set: the statement says what the sync changes, and a column the target
    // computes or a trigger maintains is left alone when it already agrees.
    private static Dictionary<string, object?> ChangedValues(DataCompareSpec spec, RowDiff diff)
    {
        var values = new Dictionary<string, object?>(diff.ChangedColumns.Count, StringComparer.Ordinal);
        foreach (var index in diff.ChangedColumns)
        {
            values[spec.Columns[index].Target] = diff.Source![index];
        }

        return values;
    }
}

/// <summary>Which engines can take a failed sync back. The rest keep every batch that ran before the failure.</summary>
public static class DataSyncTransactionality
{
    public static bool CanRollBack(DatabaseEngine engine) => engine switch
    {
        DatabaseEngine.ClickHouse or DatabaseEngine.Cassandra or DatabaseEngine.ScyllaDb or DatabaseEngine.BigQuery
            or DatabaseEngine.Redis or DatabaseEngine.MongoDb or DatabaseEngine.DynamoDb or DatabaseEngine.Elasticsearch
            or DatabaseEngine.Typesense or DatabaseEngine.Weaviate or DatabaseEngine.Kafka or DatabaseEngine.Etcd
            or DatabaseEngine.Trino or DatabaseEngine.Databend or DatabaseEngine.CloudflareD1 => false,
        _ => true,
    };
}
