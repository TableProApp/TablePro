using TablePro.Core.Localization;

namespace TablePro.Core.Plans;

/// <summary>What a plan number measures, which decides how it is spelled.</summary>
public enum QueryPlanUnit
{
    /// <summary>A planner cost: unitless, and comparable only between plans from the same server.</summary>
    Cost,

    /// <summary>A row or loop count.</summary>
    Count,

    /// <summary>A duration the plan reported, already in milliseconds.</summary>
    Milliseconds,

    /// <summary>A width in bytes.</summary>
    Bytes,
}

/// <summary>The numbers every node may report, in the order a node reads them.</summary>
public enum QueryPlanMetric
{
    EstimatedStartupCost,
    EstimatedTotalCost,
    EstimatedRows,
    EstimatedWidth,
    ActualStartupTime,
    ActualTotalTime,
    ActualRows,
    ActualLoops,
}

/// <summary>Plan-wide numbers, which live on the plan rather than on any one node.</summary>
public enum QueryPlanSummaryMetric
{
    TotalCost,
    EstimatedRows,
    PlanningTime,
    ExecutionTime,
    NodeCount,
}

public static class QueryPlanMetrics
{
    public static string Title(this QueryPlanMetric metric) => metric switch
    {
        QueryPlanMetric.EstimatedStartupCost => CoreStrings.Get("Plan/MetricEstimatedStartupCost"),
        QueryPlanMetric.EstimatedTotalCost => CoreStrings.Get("Plan/MetricEstimatedTotalCost"),
        QueryPlanMetric.EstimatedRows => CoreStrings.Get("Plan/MetricEstimatedRows"),
        QueryPlanMetric.EstimatedWidth => CoreStrings.Get("Plan/MetricEstimatedWidth"),
        QueryPlanMetric.ActualStartupTime => CoreStrings.Get("Plan/MetricActualStartupTime"),
        QueryPlanMetric.ActualTotalTime => CoreStrings.Get("Plan/MetricActualTotalTime"),
        QueryPlanMetric.ActualRows => CoreStrings.Get("Plan/MetricActualRows"),
        _ => CoreStrings.Get("Plan/MetricActualLoops"),
    };

    public static QueryPlanUnit Unit(this QueryPlanMetric metric) => metric switch
    {
        QueryPlanMetric.EstimatedStartupCost or QueryPlanMetric.EstimatedTotalCost => QueryPlanUnit.Cost,
        QueryPlanMetric.EstimatedWidth => QueryPlanUnit.Bytes,
        QueryPlanMetric.ActualStartupTime or QueryPlanMetric.ActualTotalTime => QueryPlanUnit.Milliseconds,
        _ => QueryPlanUnit.Count,
    };

    public static double? Value(this QueryPlanMetric metric, QueryPlanNode node)
    {
        ArgumentNullException.ThrowIfNull(node);
        return metric switch
        {
            QueryPlanMetric.EstimatedStartupCost => node.EstimatedStartupCost,
            QueryPlanMetric.EstimatedTotalCost => node.EstimatedTotalCost,
            QueryPlanMetric.EstimatedRows => node.EstimatedRows,
            QueryPlanMetric.EstimatedWidth => node.EstimatedWidth,
            QueryPlanMetric.ActualStartupTime => node.ActualStartupTime,
            QueryPlanMetric.ActualTotalTime => node.ActualTotalTime,
            QueryPlanMetric.ActualRows => node.ActualRows,
            _ => node.ActualLoops,
        };
    }

    public static string Title(this QueryPlanSummaryMetric metric) => metric switch
    {
        QueryPlanSummaryMetric.TotalCost => CoreStrings.Get("Plan/SummaryTotalCost"),
        QueryPlanSummaryMetric.EstimatedRows => CoreStrings.Get("Plan/SummaryEstimatedRows"),
        QueryPlanSummaryMetric.PlanningTime => CoreStrings.Get("Plan/SummaryPlanningTime"),
        QueryPlanSummaryMetric.ExecutionTime => CoreStrings.Get("Plan/SummaryExecutionTime"),
        _ => CoreStrings.Get("Plan/SummaryNodeCount"),
    };

    public static QueryPlanUnit Unit(this QueryPlanSummaryMetric metric) => metric switch
    {
        QueryPlanSummaryMetric.TotalCost => QueryPlanUnit.Cost,
        QueryPlanSummaryMetric.PlanningTime or QueryPlanSummaryMetric.ExecutionTime => QueryPlanUnit.Milliseconds,
        _ => QueryPlanUnit.Count,
    };
}

public enum QueryPlanFieldKind
{
    Summary,
    Metric,
    Property,
}

/// <summary>A named value a node or a plan reports: a summary metric, a node metric, or a property by its key.</summary>
public readonly record struct QueryPlanField
{
    private QueryPlanField(QueryPlanFieldKind kind, QueryPlanSummaryMetric summary, QueryPlanMetric metric, string? key)
    {
        Kind = kind;
        Summary = summary;
        Metric = metric;
        Key = key;
    }

    public QueryPlanFieldKind Kind { get; }

    public QueryPlanSummaryMetric Summary { get; }

    public QueryPlanMetric Metric { get; }

    public string? Key { get; }

    public static QueryPlanField ForSummary(QueryPlanSummaryMetric metric) => new(QueryPlanFieldKind.Summary, metric, default, null);

    public static QueryPlanField ForMetric(QueryPlanMetric metric) => new(QueryPlanFieldKind.Metric, default, metric, null);

    public static QueryPlanField ForProperty(string key) => new(QueryPlanFieldKind.Property, default, default, key);

    public string Title => Kind switch
    {
        QueryPlanFieldKind.Summary => Summary.Title(),
        QueryPlanFieldKind.Metric => Metric.Title(),
        _ => Key ?? string.Empty,
    };

    /// <summary>Null for a property, which is text as the engine spelled it.</summary>
    public QueryPlanUnit? Unit => Kind switch
    {
        QueryPlanFieldKind.Summary => Summary.Unit(),
        QueryPlanFieldKind.Metric => Metric.Unit(),
        _ => null,
    };

    /// <summary>
    /// Summaries, then metrics in their declared order rather than alphabetically, so a node reads startup cost then
    /// total cost the way the database prints it, then properties by key.
    /// </summary>
    internal static int Compare(QueryPlanField a, QueryPlanField b)
    {
        var byKind = a.Kind.CompareTo(b.Kind);
        if (byKind != 0)
        {
            return byKind;
        }

        return a.Kind switch
        {
            QueryPlanFieldKind.Summary => a.Summary.CompareTo(b.Summary),
            QueryPlanFieldKind.Metric => a.Metric.CompareTo(b.Metric),
            _ => string.CompareOrdinal(a.Key, b.Key),
        };
    }
}

/// <summary>A field's value: a number kept as a number until it is drawn, or text as the engine spelled it.</summary>
public readonly record struct QueryPlanFieldValue(double? Number, string? Text)
{
    public static QueryPlanFieldValue Of(double number) => new(number, null);

    public static QueryPlanFieldValue Of(string text) => new(null, text);
}

/// <summary>One field before and after.</summary>
public sealed record QueryPlanFieldChange(QueryPlanField Field, QueryPlanFieldValue? Before, QueryPlanFieldValue? After)
{
    public bool HasChange => Before != After;

    /// <summary>The signed difference, when both sides are numbers; text that changed has only a before and an after.</summary>
    public double? Delta => Before?.Number is { } before && After?.Number is { } after ? after - before : null;

    /// <summary>The current value as a multiple of the baseline; null when the baseline is zero, since that says nothing.</summary>
    public double? Ratio => Before?.Number is { } before && After?.Number is { } after && before > 0 && double.IsFinite(before) && double.IsFinite(after)
        ? after / before
        : null;
}
