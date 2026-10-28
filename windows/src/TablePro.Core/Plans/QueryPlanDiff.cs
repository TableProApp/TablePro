using System.Collections.Frozen;
using System.Globalization;

namespace TablePro.Core.Plans;

public enum QueryPlanChangeKind
{
    Added,
    Removed,
    Changed,
}

/// <summary>One node that was added, removed, or reports different values, with a path that is stable across runs.</summary>
public sealed record QueryPlanNodeChange(
    QueryPlanChangeKind Kind,
    string Path,
    string Operation,
    string? Relation,
    string? Schema,
    string? Alias,
    IReadOnlyList<QueryPlanFieldChange> FieldChanges)
{
    public string? RelationName => string.IsNullOrEmpty(Relation) ? null : Relation;

    public string Title => RelationName is { } relation ? $"{Operation}, {relation}" : Operation;
}

public enum QueryPlanVerdictKind
{
    /// <summary>Both plans measured an execution time and the current one is slower beyond the noise band.</summary>
    Slower,
    Faster,

    /// <summary>Nodes were added or removed, with no measured time to judge the effect by.</summary>
    ShapeChanged,

    /// <summary>The same nodes, but some of their values moved.</summary>
    ValuesChanged,
    Unchanged,
}

/// <summary>
/// The one-line answer a comparison leads with. A list of forty field changes does not tell a reader whether the query
/// got better, and that is the question they opened the comparison to ask.
/// </summary>
public readonly record struct QueryPlanVerdict(QueryPlanVerdictKind Kind, double Ratio = 1)
{
    public string Headline => Kind switch
    {
        QueryPlanVerdictKind.Slower => $"{Multiple(Ratio)} slower than the baseline",
        QueryPlanVerdictKind.Faster => $"{Multiple(Ratio)} faster than the baseline",
        QueryPlanVerdictKind.ShapeChanged => "The plan shape changed",
        QueryPlanVerdictKind.ValuesChanged => "Same plan shape, different numbers",
        _ => "No measurable change",
    };

    private static string Multiple(double ratio) => ratio.ToString("0.#", CultureInfo.CurrentCulture) + "x";
}

/// <summary>
/// What changed between an earlier plan and the current one. Siblings are aligned by a longest common subsequence over
/// their semantic keys: a plan node has no identity across two runs, so its identity is what it says it is, the
/// operation, the relation, the alias, and the properties that decide what kind of node it is.
/// </summary>
public sealed class QueryPlanDiff
{
    /// <summary>Two runs of an unchanged plan differ by a few percent on timing alone; inside this band a run is unchanged.</summary>
    public const double NoiseRatio = 1.15;

    /// <summary>A node whose join type or index changed is a different node, not the same node with a different number.</summary>
    private static readonly FrozenSet<string> IdentifyingPropertyKeys = FrozenSet.Create(
        StringComparer.Ordinal, "CTE Name", "Index Name", "Join Type", "Parent Relationship", "Strategy", "Subplan Name");

    private QueryPlanDiff(QueryPlanVerdict verdict, IReadOnlyList<QueryPlanFieldChange> summary, IReadOnlyList<QueryPlanNodeChange> nodeChanges)
    {
        Verdict = verdict;
        Summary = summary;
        NodeChanges = nodeChanges;
    }

    public QueryPlanVerdict Verdict { get; }

    /// <summary>Every plan-wide metric, changed or not, so the summary table always has the same rows.</summary>
    public IReadOnlyList<QueryPlanFieldChange> Summary { get; }

    public IReadOnlyList<QueryPlanNodeChange> NodeChanges { get; }

    public bool HasChanges => Verdict.Kind != QueryPlanVerdictKind.Unchanged;

    public static QueryPlanDiff Compare(QueryPlan baseline, QueryPlan current)
    {
        ArgumentNullException.ThrowIfNull(baseline);
        ArgumentNullException.ThrowIfNull(current);
        var summary = SummaryChanges(baseline, current);
        var changes = new List<QueryPlanNodeChange>();
        var baselineRoot = Keyed([baseline.Root])[0];
        var currentRoot = Keyed([current.Root])[0];
        if (baselineRoot.Key.Equals(currentRoot.Key))
        {
            CompareMatched(baseline.Root, current.Root, PathComponent(currentRoot), changes);
        }
        else
        {
            AppendSubtree(baseline.Root, QueryPlanChangeKind.Removed, PathComponent(baselineRoot), changes);
            AppendSubtree(current.Root, QueryPlanChangeKind.Added, PathComponent(currentRoot), changes);
        }

        return new QueryPlanDiff(DecideVerdict(summary, changes), summary, changes);
    }

    private static QueryPlanVerdict DecideVerdict(List<QueryPlanFieldChange> summary, List<QueryPlanNodeChange> changes)
    {
        var execution = summary.First(c => c.Field == QueryPlanField.ForSummary(QueryPlanSummaryMetric.ExecutionTime));
        if (execution.Ratio is { } ratio)
        {
            if (ratio >= NoiseRatio)
            {
                return new QueryPlanVerdict(QueryPlanVerdictKind.Slower, ratio);
            }

            if (ratio <= 1 / NoiseRatio)
            {
                return new QueryPlanVerdict(QueryPlanVerdictKind.Faster, 1 / ratio);
            }
        }

        if (changes.Any(c => c.Kind != QueryPlanChangeKind.Changed))
        {
            return new QueryPlanVerdict(QueryPlanVerdictKind.ShapeChanged);
        }

        return changes.Count > 0 || summary.Any(IsMeaningful)
            ? new QueryPlanVerdict(QueryPlanVerdictKind.ValuesChanged)
            : new QueryPlanVerdict(QueryPlanVerdictKind.Unchanged);
    }

    /// <summary>A timing only counts once it leaves the noise band; anything else counts as soon as it moves.</summary>
    private static bool IsMeaningful(QueryPlanFieldChange change)
    {
        if (!change.HasChange)
        {
            return false;
        }

        if (change.Field.Unit != QueryPlanUnit.Milliseconds || change.Ratio is not { } ratio)
        {
            return true;
        }

        return ratio >= NoiseRatio || ratio <= 1 / NoiseRatio;
    }

    private static List<QueryPlanFieldChange> SummaryChanges(QueryPlan baseline, QueryPlan current)
    {
        static QueryPlanFieldValue? Number(double? value) => value is { } v ? QueryPlanFieldValue.Of(v) : null;

        QueryPlanFieldChange Change(QueryPlanSummaryMetric metric, double? before, double? after) =>
            new(QueryPlanField.ForSummary(metric), Number(before), Number(after));

        return
        [
            Change(QueryPlanSummaryMetric.TotalCost, baseline.Root.EstimatedTotalCost, current.Root.EstimatedTotalCost),
            Change(QueryPlanSummaryMetric.EstimatedRows, baseline.Root.EstimatedRows, current.Root.EstimatedRows),
            Change(QueryPlanSummaryMetric.PlanningTime, baseline.PlanningTime, current.PlanningTime),
            Change(QueryPlanSummaryMetric.ExecutionTime, baseline.ExecutionTime, current.ExecutionTime),
            Change(QueryPlanSummaryMetric.NodeCount, baseline.NodeCount, current.NodeCount),
        ];
    }

    private readonly record struct NodeKey(string Operation, string? Schema, string? Relation, string? Alias, string Identifiers);

    private readonly record struct KeyedNode(QueryPlanNode Node, NodeKey Key, int Occurrence);

    private static NodeKey KeyOf(QueryPlanNode node) => new(
        node.Operation,
        node.Schema,
        node.Relation,
        node.Alias,
        string.Join('\u001f', node.Properties.Where(p => IdentifyingPropertyKeys.Contains(p.Key)).OrderBy(p => p.Key, StringComparer.Ordinal).Select(p => p.Key + "=" + p.Value)));

    private static List<KeyedNode> Keyed(IReadOnlyList<QueryPlanNode> nodes)
    {
        var occurrences = new Dictionary<NodeKey, int>();
        var keyed = new List<KeyedNode>(nodes.Count);
        foreach (var node in nodes)
        {
            var key = KeyOf(node);
            var occurrence = occurrences.GetValueOrDefault(key) + 1;
            occurrences[key] = occurrence;
            keyed.Add(new KeyedNode(node, key, occurrence));
        }

        return keyed;
    }

    /// <summary>A path that is stable between two runs and unique inside one plan.</summary>
    private static string PathComponent(KeyedNode keyed)
    {
        var component = keyed.Node.Operation;
        if (!string.IsNullOrEmpty(keyed.Node.Relation))
        {
            component += $"[{keyed.Node.Relation}]";
        }

        if (!string.IsNullOrEmpty(keyed.Node.Alias) && keyed.Node.Alias != keyed.Node.Relation)
        {
            component += $"({keyed.Node.Alias})";
        }

        return component.Replace('/', '∕') + "#" + keyed.Occurrence.ToString(CultureInfo.InvariantCulture);
    }

    private static void CompareMatched(QueryPlanNode baseline, QueryPlanNode current, string path, List<QueryPlanNodeChange> changes)
    {
        var fieldChanges = ChangedFields(baseline, current);
        if (fieldChanges.Count > 0)
        {
            changes.Add(new QueryPlanNodeChange(QueryPlanChangeKind.Changed, path, current.Operation, current.Relation, current.Schema, current.Alias, fieldChanges));
        }

        var baselineChildren = Keyed(baseline.Children);
        var currentChildren = Keyed(current.Children);
        var (matches, removed, inserted) = Align(baselineChildren, currentChildren);
        foreach (var index in removed)
        {
            AppendSubtree(baselineChildren[index].Node, QueryPlanChangeKind.Removed, $"{path}/{PathComponent(baselineChildren[index])}", changes);
        }

        foreach (var index in inserted)
        {
            AppendSubtree(currentChildren[index].Node, QueryPlanChangeKind.Added, $"{path}/{PathComponent(currentChildren[index])}", changes);
        }

        foreach (var (b, c) in matches)
        {
            CompareMatched(baselineChildren[b].Node, currentChildren[c].Node, $"{path}/{PathComponent(currentChildren[c])}", changes);
        }
    }

    /// <summary>
    /// Pairs siblings along a longest common subsequence of their keys, so a node inserted between two that stayed does
    /// not report the whole tail as rewritten. Ties go to the earliest match, so of two identical siblings the second is
    /// the one reported missing.
    /// </summary>
    private static (List<(int Baseline, int Current)> Matches, List<int> Removed, List<int> Inserted) Align(List<KeyedNode> baseline, List<KeyedNode> current)
    {
        var lengths = new int[baseline.Count + 1, current.Count + 1];
        for (var i = baseline.Count - 1; i >= 0; i--)
        {
            for (var j = current.Count - 1; j >= 0; j--)
            {
                lengths[i, j] = baseline[i].Key.Equals(current[j].Key)
                    ? lengths[i + 1, j + 1] + 1
                    : Math.Max(lengths[i + 1, j], lengths[i, j + 1]);
            }
        }

        var matches = new List<(int, int)>();
        var removed = new List<int>();
        var inserted = new List<int>();
        int bi = 0, ci = 0;
        while (bi < baseline.Count && ci < current.Count)
        {
            if (baseline[bi].Key.Equals(current[ci].Key))
            {
                matches.Add((bi++, ci++));
            }
            else if (lengths[bi + 1, ci] >= lengths[bi, ci + 1])
            {
                removed.Add(bi++);
            }
            else
            {
                inserted.Add(ci++);
            }
        }

        while (bi < baseline.Count)
        {
            removed.Add(bi++);
        }

        while (ci < current.Count)
        {
            inserted.Add(ci++);
        }

        return (matches, removed, inserted);
    }

    private static void AppendSubtree(QueryPlanNode node, QueryPlanChangeKind kind, string path, List<QueryPlanNodeChange> changes)
    {
        var fields = Fields(node)
            .OrderBy(f => f.Key, Comparer<QueryPlanField>.Create(QueryPlanField.Compare))
            .Select(f => new QueryPlanFieldChange(f.Key, kind == QueryPlanChangeKind.Removed ? f.Value : null, kind == QueryPlanChangeKind.Added ? f.Value : null))
            .ToList();
        changes.Add(new QueryPlanNodeChange(kind, path, node.Operation, node.Relation, node.Schema, node.Alias, fields));
        foreach (var child in Keyed(node.Children))
        {
            AppendSubtree(child.Node, kind, $"{path}/{PathComponent(child)}", changes);
        }
    }

    private static List<QueryPlanFieldChange> ChangedFields(QueryPlanNode baseline, QueryPlanNode current)
    {
        var before = Fields(baseline);
        var after = Fields(current);
        return before.Keys.Union(after.Keys)
            .Order(Comparer<QueryPlanField>.Create(QueryPlanField.Compare))
            .Select(f => new QueryPlanFieldChange(f, before.TryGetValue(f, out var b) ? b : null, after.TryGetValue(f, out var a) ? a : null))
            .Where(c => c.HasChange)
            .ToList();
    }

    /// <summary>
    /// Reads the properties directly rather than through <see cref="QueryPlanLabels.VisibleProperties"/>, which drops
    /// a value spelled 0: "Rows Removed by Filter" falling from 1000 to 0 is the improvement the reader came to find,
    /// and hiding the zero would report it as the property disappearing.
    /// </summary>
    private static Dictionary<QueryPlanField, QueryPlanFieldValue> Fields(QueryPlanNode node)
    {
        var fields = new Dictionary<QueryPlanField, QueryPlanFieldValue>();
        foreach (var metric in Enum.GetValues<QueryPlanMetric>())
        {
            if (metric.Value(node) is { } value)
            {
                fields[QueryPlanField.ForMetric(metric)] = QueryPlanFieldValue.Of(value);
            }
        }

        foreach (var (key, value) in node.Properties)
        {
            if (!QueryPlanLabels.HiddenPropertyKeys.Contains(key))
            {
                fields[QueryPlanField.ForProperty(key)] = QueryPlanFieldValue.Of(value);
            }
        }

        return fields;
    }
}
