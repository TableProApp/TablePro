using System.Globalization;
using TablePro.Interop;

namespace TablePro.App.Model;

// Which per-node figure the plan tree's magnitude bars show.
public enum PlanMetric
{
    Cost,
    Rows,
}

// One node laid out for the plan tree: its depth from the root, the share [0,1] its bar fills for the chosen metric,
// and the figure beside the bar. Magnitude and MetricText are null where the node carries no such figure.
public sealed record QueryPlanRow(QueryPlanNode Node, int Depth, double? Magnitude, string? MetricText);

// The plan tree flattened for the view: the metrics the plan carries, and a pre-order row list with per-node bars.
public static class QueryPlanRows
{
    // The metrics every node could show, so the picker offers only what the plan carries. Cost first.
    public static IReadOnlyList<PlanMetric> MetricsFor(QueryPlan plan)
    {
        ArgumentNullException.ThrowIfNull(plan);
        var metrics = new List<PlanMetric>(2);
        if (Any(plan.Root, node => node.CostFraction is not null))
        {
            metrics.Add(PlanMetric.Cost);
        }

        if (Any(plan.Root, node => node.EstimatedRows is not null))
        {
            metrics.Add(PlanMetric.Rows);
        }

        return metrics;
    }

    // Pre-order rows carrying each node's depth. The cost bar is the node's share of the plan's work; the rows bar is
    // the node's estimate over the plan's largest, so the busiest node fills it.
    public static IReadOnlyList<QueryPlanRow> Flatten(QueryPlan plan, PlanMetric metric)
    {
        ArgumentNullException.ThrowIfNull(plan);
        var largestRows = metric == PlanMetric.Rows ? Largest(plan.Root) : 0;
        var rows = new List<QueryPlanRow>();
        Walk(plan.Root, 0, metric, largestRows, rows);
        return rows;
    }

    private static void Walk(QueryPlanNode node, int depth, PlanMetric metric, long largestRows, List<QueryPlanRow> rows)
    {
        rows.Add(Row(node, depth, metric, largestRows));
        foreach (var child in node.Children)
        {
            Walk(child, depth + 1, metric, largestRows, rows);
        }
    }

    private static QueryPlanRow Row(QueryPlanNode node, int depth, PlanMetric metric, long largestRows) => metric switch
    {
        PlanMetric.Rows => new QueryPlanRow(
            node,
            depth,
            node.EstimatedRows is { } count && largestRows > 0 ? (double)count / largestRows : null,
            node.EstimatedRows is { } rows ? rows.ToString("N0", CultureInfo.CurrentCulture) : null),
        _ => new QueryPlanRow(
            node,
            depth,
            node.CostFraction,
            node.CostFraction is { } fraction ? fraction.ToString("P0", CultureInfo.CurrentCulture) : null),
    };

    private static long Largest(QueryPlanNode node)
    {
        var largest = node.EstimatedRows ?? 0;
        foreach (var child in node.Children)
        {
            largest = Math.Max(largest, Largest(child));
        }

        return largest;
    }

    private static bool Any(QueryPlanNode node, Func<QueryPlanNode, bool> predicate) =>
        predicate(node) || node.Children.Any(child => Any(child, predicate));
}
