using System.Globalization;
using System.Text;
using TablePro.Core.Plans;

namespace TablePro.App.Localization;

/// <summary>
/// Translated names and descriptions for the query plan views, which Core spells in English. Property keys, operation
/// names and values come from the engine and pass through as reported.
/// </summary>
internal static class PlanNames
{
    public static string Title(QueryPlanBarMetric metric) => metric switch
    {
        QueryPlanBarMetric.SelfCost => Strings.Get("Plan/BarMetricSelfCost"),
        QueryPlanBarMetric.SelfTime => Strings.Get("Plan/BarMetricSelfTime"),
        QueryPlanBarMetric.EstimatedRows => Title(QueryPlanMetric.EstimatedRows),
        _ => Title(QueryPlanMetric.ActualRows),
    };

    public static string Title(QueryPlanMetric metric) => metric switch
    {
        QueryPlanMetric.EstimatedStartupCost => Strings.Get("Plan/MetricEstimatedStartupCost"),
        QueryPlanMetric.EstimatedTotalCost => Strings.Get("Plan/MetricEstimatedTotalCost"),
        QueryPlanMetric.EstimatedRows => Strings.Get("Plan/MetricEstimatedRows"),
        QueryPlanMetric.EstimatedWidth => Strings.Get("Plan/MetricEstimatedWidth"),
        QueryPlanMetric.ActualStartupTime => Strings.Get("Plan/MetricActualStartupTime"),
        QueryPlanMetric.ActualTotalTime => Strings.Get("Plan/MetricActualTotalTime"),
        QueryPlanMetric.ActualRows => Strings.Get("Plan/MetricActualRows"),
        _ => Strings.Get("Plan/MetricActualLoops"),
    };

    public static string Title(QueryPlanSummaryMetric metric) => metric switch
    {
        QueryPlanSummaryMetric.TotalCost => Strings.Get("Plan/SummaryTotalCost"),
        QueryPlanSummaryMetric.EstimatedRows => Strings.Get("Plan/SummaryEstimatedRows"),
        QueryPlanSummaryMetric.PlanningTime => Strings.Get("Plan/SummaryPlanningTime"),
        QueryPlanSummaryMetric.ExecutionTime => Strings.Get("Plan/SummaryExecutionTime"),
        _ => Strings.Get("Plan/SummaryNodeCount"),
    };

    public static string Title(QueryPlanField field) => field.Kind switch
    {
        QueryPlanFieldKind.Summary => Title(field.Summary),
        QueryPlanFieldKind.Metric => Title(field.Metric),
        _ => field.Key ?? string.Empty,
    };

    /// <summary>What a screen reader says for a severity badge.</summary>
    public static string Label(QueryPlanSeverity severity) => severity switch
    {
        QueryPlanSeverity.Low => Strings.Get("Plan/SeverityLow"),
        QueryPlanSeverity.Moderate => Strings.Get("Plan/SeverityModerate"),
        QueryPlanSeverity.High => Strings.Get("Plan/SeverityHigh"),
        _ => Strings.Get("Plan/SeverityCritical"),
    };

    public static string Headline(QueryPlanVerdict verdict) => verdict.Kind switch
    {
        QueryPlanVerdictKind.Slower => Strings.Format("Plan/VerdictSlower", verdict.Ratio),
        QueryPlanVerdictKind.Faster => Strings.Format("Plan/VerdictFaster", verdict.Ratio),
        QueryPlanVerdictKind.ShapeChanged => Strings.Get("Plan/VerdictShapeChanged"),
        QueryPlanVerdictKind.ValuesChanged => Strings.Get("Plan/VerdictValuesChanged"),
        _ => Strings.Get("Plan/VerdictUnchanged"),
    };

    /// <summary>The signed difference Core formats, or a translated word when the change has no number to show.</summary>
    public static string? Change(QueryPlanFieldChange change)
    {
        ArgumentNullException.ThrowIfNull(change);
        if (change.HasChange && (change.Delta is null || change.Field.Unit is null))
        {
            return Strings.Get("Plan/ValueChanged");
        }

        return QueryPlanValueFormatter.Change(change);
    }

    /// <summary>One spoken sentence: what the step does, on what, and how expensive it is.</summary>
    public static string AccessibleName(QueryPlanNode node)
    {
        ArgumentNullException.ThrowIfNull(node);
        var parts = new List<string>(6) { node.Operation };
        if (node.Relation is { } relation)
        {
            parts.Add(Strings.Format("Plan/AccessibleOnRelation", relation));
        }

        if (node.Severity is { } severity)
        {
            parts.Add(Label(severity));
        }

        if (node.Warnings.Count > 0)
        {
            parts.Add(Strings.Plural("Plan/AccessibleWarnings", node.Warnings.Count));
        }

        if (node.CostRangeText(2) is { } cost)
        {
            parts.Add(Strings.Format("Plan/AccessibleCost", cost));
        }

        if (node.EstimatedRows is { } rows)
        {
            parts.Add(Strings.Plural("Plan/AccessibleRows", rows));
        }

        if (node.ActualTotalTime is { } time)
        {
            parts.Add(Strings.Format("Plan/AccessibleActualTime", QueryPlanLabels.Milliseconds(time)));
        }

        return string.Join(Strings.Get("Plan/AccessibleSeparator"), parts);
    }

    /// <summary>The whole step as label and value lines, for its tooltip and Copy Step Details.</summary>
    public static string Text(QueryPlanNode node)
    {
        ArgumentNullException.ThrowIfNull(node);
        var text = new StringBuilder(node.Operation);
        void Line(string label, string value) => text.Append('\n').Append(Strings.Format("Plan/LabelValue", label, value));

        if (node.Relation is { } relation)
        {
            Line(Strings.Get("Plan/LabelTable"), relation);
        }

        if (node.CostRangeText(2) is { } cost)
        {
            Line(Strings.Get("Plan/LabelCost"), cost);
        }

        if (node.EstimatedRows is { } rows)
        {
            Line(Strings.Get("Plan/LabelRows"), rows.ToString(CultureInfo.InvariantCulture));
        }

        if (node.EstimatedWidth is { } width and > 0)
        {
            Line(Strings.Get("Plan/LabelWidth"), width.ToString(CultureInfo.InvariantCulture));
        }

        if (node.ActualTotalTime is { } time)
        {
            Line(Strings.Get("Plan/LabelActualTime"), QueryPlanLabels.Milliseconds(time));
        }

        if (node.ActualRows is { } actualRows)
        {
            Line(Strings.Get("Plan/LabelActualRows"), actualRows.ToString(CultureInfo.InvariantCulture));
        }

        if (node.ActualLoops is { } loops and > 1)
        {
            Line(Strings.Get("Plan/LabelLoops"), loops.ToString(CultureInfo.InvariantCulture));
        }

        foreach (var (key, value) in QueryPlanLabels.VisibleProperties(node))
        {
            Line(key, value);
        }

        foreach (var warning in node.Warnings)
        {
            Line(Strings.Get("Plan/LabelWarning"), warning);
        }

        foreach (var index in node.MissingIndexes)
        {
            Line(Strings.Get("Plan/LabelMissingIndex"), index.CreateStatement);
        }

        return text.ToString();
    }
}
