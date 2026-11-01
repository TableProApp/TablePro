using System.Globalization;

namespace TablePro.Core.Plans;

/// <summary>
/// One step of a query plan. A node is identified by reference: two siblings that read the same table the same way
/// are still two steps, so the type keeps reference equality and works as a dictionary key as it is.
/// </summary>
public sealed class QueryPlanNode
{
    private static readonly IReadOnlyDictionary<string, string> NoProperties = new Dictionary<string, string>(0, StringComparer.Ordinal);

    public required string Operation { get; init; }

    public string? Relation { get; init; }

    public string? Schema { get; init; }

    public string? Alias { get; init; }

    public double? EstimatedStartupCost { get; init; }

    public double? EstimatedTotalCost { get; init; }

    public long? EstimatedRows { get; init; }

    public long? EstimatedWidth { get; init; }

    /// <summary>Milliseconds, averaged per loop as PostgreSQL reports it.</summary>
    public double? ActualStartupTime { get; init; }

    /// <summary>Milliseconds spent in this node and everything below it, averaged per loop.</summary>
    public double? ActualTotalTime { get; init; }

    /// <summary>Rows per loop.</summary>
    public long? ActualRows { get; init; }

    public long? ActualLoops { get; init; }

    /// <summary>
    /// A total over every execution, kept when the plan reports one: the per-loop average is rounded, so multiplying
    /// it back loses rows a step returned once over many starts.
    /// </summary>
    public long? ReportedTotalActualRows { get; init; }

    /// <summary>Everything else the engine reported for the node, keyed as the engine spells it.</summary>
    public IReadOnlyDictionary<string, string> Properties { get; init; } = NoProperties;

    public IReadOnlyList<QueryPlanNode> Children { get; init; } = [];

    public IReadOnlyList<string> Warnings { get; init; } = [];

    public IReadOnlyList<QueryPlanMissingIndex> MissingIndexes { get; init; } = [];

    /// <summary>
    /// This node's share of the plan's total work, 0 to 1, set once the tree is built. Null when the plan reports
    /// no cost anywhere, which is not the same as a share of zero.
    /// </summary>
    public double? CostFraction { get; internal set; }

    /// <summary>Null when the plan reported no cost at all, so an unmeasured node is never called cheap.</summary>
    public QueryPlanSeverity? Severity => CostFraction is { } share ? QueryPlanSeverities.ForShare(share) : null;

    /// <summary>The cost of this node alone, without what its children cost; never negative.</summary>
    public double ExclusiveCost
    {
        get
        {
            var childCost = 0d;
            foreach (var child in Children)
            {
                childCost += child.EstimatedTotalCost ?? 0;
            }

            return Math.Max(0, (EstimatedTotalCost ?? 0) - childCost);
        }
    }

    /// <summary>Total rows this node produced. Workers do not divide a row count: every worker's rows reach the parent.</summary>
    public long? TotalActualRows => ReportedTotalActualRows ?? (ActualRows is { } perLoop ? perLoop * Math.Max(ActualLoops ?? 1, 1) : null);

    /// <summary><c>startup..total</c> when the plan reports both, the total alone when it reports only that.</summary>
    public string? CostRangeText(int fractionDigits)
    {
        if (EstimatedTotalCost is not { } total)
        {
            return null;
        }

        var format = "F" + fractionDigits.ToString(CultureInfo.InvariantCulture);
        return EstimatedStartupCost is { } startup
            ? string.Concat(startup.ToString(format, CultureInfo.InvariantCulture), "..", total.ToString(format, CultureInfo.InvariantCulture))
            : total.ToString(format, CultureInfo.InvariantCulture);
    }

    /// <summary>Time spent in this node and below it over every loop, divided across the processes that ran it at once.</summary>
    public double? TotalTime(int processCount)
    {
        if (ActualTotalTime is not { } perLoop)
        {
            return null;
        }

        return perLoop * Math.Max(ActualLoops ?? 1, 1) / Math.Max(processCount, 1);
    }

    /// <summary>The same step with statement-level findings attached, as SQL Server reports them beside the tree.</summary>
    internal QueryPlanNode WithDiagnostics(IReadOnlyList<string> warnings, IReadOnlyList<QueryPlanMissingIndex> missingIndexes)
    {
        if (warnings.Count == 0 && missingIndexes.Count == 0)
        {
            return this;
        }

        return new QueryPlanNode
        {
            Operation = Operation,
            Relation = Relation,
            Schema = Schema,
            Alias = Alias,
            EstimatedStartupCost = EstimatedStartupCost,
            EstimatedTotalCost = EstimatedTotalCost,
            EstimatedRows = EstimatedRows,
            EstimatedWidth = EstimatedWidth,
            ActualStartupTime = ActualStartupTime,
            ActualTotalTime = ActualTotalTime,
            ActualRows = ActualRows,
            ActualLoops = ActualLoops,
            ReportedTotalActualRows = ReportedTotalActualRows,
            Properties = Properties,
            Children = Children,
            Warnings = [.. Warnings, .. warnings],
            MissingIndexes = [.. MissingIndexes, .. missingIndexes],
        };
    }

    public override string ToString() => Relation is null ? Operation : $"{Operation} on {Relation}";
}

/// <summary>An index the server says would have helped, with the statement that creates it.</summary>
public sealed record QueryPlanMissingIndex(double? Impact, string CreateStatement);
