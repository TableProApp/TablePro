using System.Collections.Frozen;

namespace TablePro.Core.Plans;

/// <summary>
/// What the outline's magnitude column charts. Every metric is exclusive or per node on purpose: an inclusive one
/// makes the root the largest bar in every plan, which says nothing about where the work is.
/// </summary>
public enum QueryPlanBarMetric
{
    SelfCost,
    SelfTime,
    EstimatedRows,
    ActualRows,
}

public static class QueryPlanBarMetrics
{
    public static string Title(this QueryPlanBarMetric metric) => metric switch
    {
        QueryPlanBarMetric.SelfCost => "Self Cost",
        QueryPlanBarMetric.SelfTime => "Self Time",
        QueryPlanBarMetric.EstimatedRows => QueryPlanMetric.EstimatedRows.Title(),
        _ => QueryPlanMetric.ActualRows.Title(),
    };

    public static QueryPlanUnit Unit(this QueryPlanBarMetric metric) => metric switch
    {
        QueryPlanBarMetric.SelfCost => QueryPlanUnit.Cost,
        QueryPlanBarMetric.SelfTime => QueryPlanUnit.Milliseconds,
        _ => QueryPlanUnit.Count,
    };

    /// <summary>
    /// Whether the plan's values sum to a meaningful whole. Self cost and self time do, so a node's part of the total
    /// is its share of the query. Row counts do not: a parent re-reports the rows its children produced.
    /// </summary>
    public static bool IsAdditive(this QueryPlanBarMetric metric) => metric is QueryPlanBarMetric.SelfCost or QueryPlanBarMetric.SelfTime;

    /// <summary>How the weight is phrased, which differs because the denominator differs; a row count is no share.</summary>
    public static string EmphasisDescription(this QueryPlanBarMetric metric, string formatted) =>
        metric.IsAdditive() ? $"{formatted} of the plan" : $"{formatted} of the largest step";
}

/// <summary>
/// One metric's value for every node, resolved once so a row never walks the tree. A bar's length is the value over
/// the largest node's, so the biggest step fills the track; its colour comes from <see cref="Emphasis"/>, which for an
/// additive metric is the share of the whole plan, so a step that is 90% of the query looks alarming even beside a
/// near-equal sibling.
/// </summary>
public sealed class QueryPlanMetricIndex
{
    private readonly FrozenDictionary<QueryPlanNode, double> _values;
    private readonly double _maximum;
    private readonly double _total;

    private QueryPlanMetricIndex(QueryPlanBarMetric metric, Dictionary<QueryPlanNode, double> values)
    {
        Metric = metric;
        _values = values.ToFrozenDictionary(ReferenceEqualityComparer.Instance);
        _maximum = values.Values.Max();
        _total = values.Values.Sum();
    }

    public QueryPlanBarMetric Metric { get; }

    /// <summary>Null when no node reports the metric: a column with nothing to draw, not a column of zero bars.</summary>
    public static QueryPlanMetricIndex? Create(QueryPlanBarMetric metric, QueryPlan plan)
    {
        ArgumentNullException.ThrowIfNull(plan);
        var values = Values(metric, plan);
        return values.Count == 0 ? null : new QueryPlanMetricIndex(metric, values);
    }

    public double? Value(QueryPlanNode node) => _values.TryGetValue(node, out var value) ? value : null;

    /// <summary>The bar's length as a part of the track. Zero stays zero, so a node that did no work draws nothing.</summary>
    public double? Fraction(QueryPlanNode node) =>
        _values.TryGetValue(node, out var value) && _maximum > 0 ? Math.Clamp(value / _maximum, 0, 1) : null;

    /// <summary>The bar's weight, which drives its colour.</summary>
    public double? Emphasis(QueryPlanNode node)
    {
        if (!_values.TryGetValue(node, out var value))
        {
            return null;
        }

        var denominator = Metric.IsAdditive() ? _total : _maximum;
        return denominator > 0 ? Math.Clamp(value / denominator, 0, 1) : null;
    }

    /// <summary>
    /// Only an additive metric has a severity: the bands mean "this much of the plan", and a plan that passes 500 rows
    /// through every step would otherwise paint every row bar critical for all being the maximum.
    /// </summary>
    public QueryPlanSeverity? Severity(QueryPlanNode node) =>
        Metric.IsAdditive() && Emphasis(node) is { } emphasis ? QueryPlanSeverities.ForShare(emphasis) : null;

    /// <summary>The metrics this plan can chart, resolved per plan: one connection reports timings only under ANALYZE.</summary>
    public static IReadOnlyList<QueryPlanBarMetric> AvailableMetrics(QueryPlan plan)
    {
        ArgumentNullException.ThrowIfNull(plan);
        return Enum.GetValues<QueryPlanBarMetric>().Where(m => plan.Nodes.Any(n => HasValue(m, n))).ToList();
    }

    /// <summary>Measured time when the plan has it, the estimate when it does not, otherwise whatever it reports.</summary>
    public static QueryPlanBarMetric? DefaultMetric(IReadOnlyList<QueryPlanBarMetric> available)
    {
        ArgumentNullException.ThrowIfNull(available);
        if (available.Contains(QueryPlanBarMetric.SelfTime))
        {
            return QueryPlanBarMetric.SelfTime;
        }

        if (available.Contains(QueryPlanBarMetric.SelfCost))
        {
            return QueryPlanBarMetric.SelfCost;
        }

        return available.Count > 0 ? available[0] : null;
    }

    private static bool HasValue(QueryPlanBarMetric metric, QueryPlanNode node) => metric switch
    {
        QueryPlanBarMetric.SelfCost => node.EstimatedTotalCost is not null,
        QueryPlanBarMetric.SelfTime => node.ActualTotalTime is not null,
        QueryPlanBarMetric.EstimatedRows => node.EstimatedRows is not null,
        _ => node.TotalActualRows is not null,
    };

    private static Dictionary<QueryPlanNode, double> Values(QueryPlanBarMetric metric, QueryPlan plan)
    {
        var values = new Dictionary<QueryPlanNode, double>(ReferenceEqualityComparer.Instance);
        var processes = metric == QueryPlanBarMetric.SelfTime ? QueryPlanLoopCorrection.ProcessCounts(plan.Root) : null;
        foreach (var node in plan.Nodes)
        {
            double? value = metric switch
            {
                QueryPlanBarMetric.SelfCost => node.EstimatedTotalCost is null ? null : node.ExclusiveCost,
                QueryPlanBarMetric.SelfTime => SelfTime(node, processes!),
                QueryPlanBarMetric.EstimatedRows => node.EstimatedRows,
                _ => node.TotalActualRows,
            };

            if (value is { } v)
            {
                values[node] = v;
            }
        }

        return values;
    }

    /// <summary>A child that reported no time adds nothing rather than voiding its parent, so a skipped branch cannot make its parent look busy.</summary>
    private static double? SelfTime(QueryPlanNode node, IReadOnlyDictionary<QueryPlanNode, int> processes)
    {
        if (node.TotalTime(processes.GetValueOrDefault(node, 1)) is not { } own)
        {
            return null;
        }

        var children = 0d;
        foreach (var child in node.Children)
        {
            children += child.TotalTime(processes.GetValueOrDefault(child, 1)) ?? 0;
        }

        return Math.Max(0, own - children);
    }
}

/// <summary>
/// Turns per-execution averages into totals. PostgreSQL: "Multiply by the loops value to get the total time actually
/// spent in the node." Under a Gather the loop count is the number of processes that ran the node at the same time,
/// so dividing by the worker count undoes that; the divisor belongs to the Gather's descendants, not the Gather, which
/// runs once in the leader. With it, a plan's exclusive durations sum to its execution time.
/// </summary>
public static class QueryPlanLoopCorrection
{
    /// <summary>How many processes ran each node: 1 outside a Gather, the launched workers plus the leader beneath one.</summary>
    public static IReadOnlyDictionary<QueryPlanNode, int> ProcessCounts(QueryPlanNode root)
    {
        ArgumentNullException.ThrowIfNull(root);
        var counts = new Dictionary<QueryPlanNode, int>(ReferenceEqualityComparer.Instance);
        var stack = new Stack<(QueryPlanNode Node, int Inherited)>();
        stack.Push((root, 1));
        while (stack.TryPop(out var item))
        {
            counts[item.Node] = item.Inherited;
            var below = ChildProcessCount(item.Node, item.Inherited);
            foreach (var child in item.Node.Children)
            {
                stack.Push((child, below));
            }
        }

        return counts;
    }

    /// <summary>A Gather that launched no workers keeps the outer count, so a plan that got no parallelism is corrected as the serial plan it was.</summary>
    private static int ChildProcessCount(QueryPlanNode node, int inherited)
    {
        if (!node.Operation.StartsWith("Gather", StringComparison.Ordinal))
        {
            return inherited;
        }

        return node.Properties.TryGetValue("Workers Launched", out var text) && int.TryParse(text, System.Globalization.CultureInfo.InvariantCulture, out var launched) && launched > 0
            ? launched + 1
            : inherited;
    }
}
