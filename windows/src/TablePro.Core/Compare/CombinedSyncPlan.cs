using TablePro.Core.Drivers;
using TablePro.Core.Editing;
using TablePro.Core.Localization;
using TablePro.Core.Schema;
using TablePro.Core.Sql;

namespace TablePro.Core.Compare;

/// <summary>One table's compared rows as a combined sync takes them.</summary>
/// <param name="Result">A finished comparison.</param>
/// <param name="ExcludedKeys">Row identities the user unticked in that table.</param>
/// <param name="SourceStructure">The source table's structure, whose foreign keys decide the order across tables.</param>
public sealed record CombinedSyncInput(DataDiffResult Result, IReadOnlySet<string>? ExcludedKeys = null, TableStructure? SourceStructure = null);

/// <summary>A run of one kind of statement against one table, applied in one call to the target session.</summary>
public sealed record SyncSegment(ObjectName Table, SyncStepKind Kind, IReadOnlyList<SyncStep> Steps)
{
    public IReadOnlyList<RowChange> Changes => [.. Steps.Select(s => s.Change)];
}

/// <summary>
/// The sync for many tables at once, reviewed as one script. Statements are ordered across tables, not only within
/// one: every table's inserts run parent first, then the updates, then the deletes child first, the only order that
/// satisfies a foreign key in both directions. Ported from the macOS app's <c>orderedAcrossTables</c>.
/// </summary>
public sealed class CombinedSyncPlan
{
    private CombinedSyncPlan(IReadOnlyList<DataSyncPlan> tables, IReadOnlyList<SyncSegment> segments, IReadOnlyList<string> warnings)
    {
        Tables = tables;
        Segments = segments;
        Warnings = warnings;
    }

    /// <summary>Each table's own plan, parent tables first.</summary>
    public IReadOnlyList<DataSyncPlan> Tables { get; }

    /// <summary>The statements in the order they run.</summary>
    public IReadOnlyList<SyncSegment> Segments { get; }

    public IReadOnlyList<string> Warnings { get; }

    public int StepCount => Segments.Sum(s => s.Steps.Count);

    public int InsertCount => Tables.Sum(t => t.InsertCount);

    public int UpdateCount => Tables.Sum(t => t.UpdateCount);

    public int DeleteCount => Tables.Sum(t => t.DeleteCount);

    public bool IsEmpty => Segments.Count == 0;

    /// <param name="tables">The compared tables to sync. A truncated comparison is left out with a warning, since its plan would cover only part of the differences.</param>
    /// <param name="options">Which kinds of difference to write.</param>
    public static CombinedSyncPlan Build(IReadOnlyList<CombinedSyncInput> tables, DataCompareOptions options)
    {
        ArgumentNullException.ThrowIfNull(tables);
        ArgumentNullException.ThrowIfNull(options);

        var warnings = new List<string>();
        var plans = new List<(DataSyncPlan Plan, CombinedSyncInput Input)>(tables.Count);
        foreach (var input in tables)
        {
            if (input.Result.IsTruncated)
            {
                warnings.Add(CoreStrings.Format("Compare/TableLeftOutTooMany", input.Result.Spec.TargetTable, input.Result.DifferenceCount));
                continue;
            }

            var plan = DataSyncPlan.Build(input.Result, options, input.ExcludedKeys);
            if (!plan.IsEmpty)
            {
                plans.Add((plan, input));
                warnings.AddRange(plan.Warnings.Select(w => CoreStrings.Format("Compare/TableNote", plan.Table, w)));
            }
        }

        var (order, cycle) = ParentsFirst(plans.Select(p => p.Input).ToList());
        if (cycle.Count > 0)
        {
            warnings.Add(CoreStrings.Format("Compare/ForeignKeyCycle", string.Join(", ", cycle)));
        }

        var ordered = order.Select(i => plans[i].Plan).ToArray();
        var segments = new List<SyncSegment>();
        AddSegments(segments, ordered, SyncStepKind.Insert);
        AddSegments(segments, ordered, SyncStepKind.Update);
        AddSegments(segments, Enumerable.Reverse(ordered), SyncStepKind.Delete);
        return new CombinedSyncPlan(ordered, segments, warnings);
    }

    /// <summary>The statements with their values written in, in run order, for the review sheet and the history.</summary>
    public IReadOnlyList<string> Preview(IDatabaseSession target)
    {
        ArgumentNullException.ThrowIfNull(target);
        if (target is not IChangePreviewProvider custom)
        {
            return Preview(target.Dialect);
        }

        var statements = new List<string>(StepCount);
        foreach (var segment in Segments)
        {
            statements.AddRange(custom.PreviewChanges(segment.Table, segment.Changes));
        }

        return statements;
    }

    public IReadOnlyList<string> Preview(SqlDialect dialect) =>
        [.. Segments.SelectMany(segment => segment.Steps.Select(s => ChangeSqlBuilder.Preview(dialect, segment.Table, s.Change)))];

    private static void AddSegments(List<SyncSegment> segments, IEnumerable<DataSyncPlan> plans, SyncStepKind kind)
    {
        foreach (var plan in plans)
        {
            var steps = plan.Steps.Where(s => s.Kind == kind).ToArray();
            if (steps.Length > 0)
            {
                segments.Add(new SyncSegment(plan.Table, kind, steps));
            }
        }
    }

    /// <summary>
    /// A stable topological order of the tables, parents before the children that reference them. Tables caught in a
    /// cycle keep their given order after the rest and are named, since no order can satisfy them.
    /// </summary>
    private static (List<int> Order, List<string> Cycle) ParentsFirst(List<CombinedSyncInput> inputs)
    {
        var parents = new List<HashSet<int>>(inputs.Count);
        for (var i = 0; i < inputs.Count; i++)
        {
            var references = new HashSet<int>();
            foreach (var key in inputs[i].SourceStructure?.ForeignKeys ?? [])
            {
                var parent = inputs.FindIndex(other => References(key.ReferencedTable, other.Result.Spec.SourceTable));
                if (parent >= 0 && parent != i)
                {
                    references.Add(parent);
                }
            }

            parents.Add(references);
        }

        var order = new List<int>(inputs.Count);
        var placed = new bool[inputs.Count];
        bool progressed;
        do
        {
            progressed = false;
            for (var i = 0; i < inputs.Count; i++)
            {
                if (!placed[i] && parents[i].All(p => placed[p]))
                {
                    placed[i] = true;
                    order.Add(i);
                    progressed = true;
                }
            }
        }
        while (progressed);

        var cycle = new List<string>();
        for (var i = 0; i < inputs.Count; i++)
        {
            if (!placed[i])
            {
                order.Add(i);
                cycle.Add(inputs[i].Result.Spec.TargetTable.ToString());
            }
        }

        return (order, cycle);
    }

    // A foreign key often names its parent without a schema, so a bare name matches the table in any schema.
    private static bool References(ObjectName referenced, ObjectName table) =>
        string.Equals(referenced.Name, table.Name, StringComparison.OrdinalIgnoreCase)
        && (string.IsNullOrEmpty(referenced.Schema) || string.IsNullOrEmpty(table.Schema) || string.Equals(referenced.Schema, table.Schema, StringComparison.OrdinalIgnoreCase));
}
