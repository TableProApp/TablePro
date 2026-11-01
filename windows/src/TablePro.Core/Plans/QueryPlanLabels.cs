using System.Collections.Frozen;
using System.Globalization;
using System.Text;
using TablePro.Core.Localization;

namespace TablePro.Core.Plans;

/// <summary>Which properties a node shows, and the plain-text renderings of a node for copying and screen readers.</summary>
public static class QueryPlanLabels
{
    /// <summary>Boolean flags a driver reports that add nothing to the display.</summary>
    public static readonly FrozenSet<string> HiddenPropertyKeys = FrozenSet.Create(StringComparer.Ordinal, "Parallel Aware", "Async Capable", "Disabled", "Inner Unique");

    /// <summary>
    /// Properties whose zero is the answer rather than the absence of one. PostgreSQL reports <c>Workers Planned: 2,
    /// Workers Launched: 0</c> when the server had no worker slots left, which is why the query was slow; dropping the
    /// zero left the planned count unopposed and the plan read as parallel.
    /// </summary>
    public static readonly FrozenSet<string> SignificantZeroKeys = FrozenSet.Create(StringComparer.Ordinal, "Workers Launched", "Actual Rows", "Actual Loops", "Heap Fetches");

    /// <summary>The properties worth showing in an inspector, sorted by key.</summary>
    public static IReadOnlyList<KeyValuePair<string, string>> VisibleProperties(QueryPlanNode node)
    {
        ArgumentNullException.ThrowIfNull(node);
        return node.Properties.Where(p => IsVisible(p.Key, p.Value)).OrderBy(p => p.Key, StringComparer.Ordinal).ToList();
    }

    public static string Milliseconds(double value) => value.ToString("F3", CultureInfo.InvariantCulture) + "ms";

    /// <summary>The whole node as <c>Label: value</c> lines, for Copy Node Details.</summary>
    public static string Text(QueryPlanNode node)
    {
        ArgumentNullException.ThrowIfNull(node);
        var text = new StringBuilder(node.Operation);
        void Line(string label, string value) => text.Append('\n').Append(CoreStrings.Format("Plan/LabelValue", label, value));

        if (node.Relation is { } relation)
        {
            Line(CoreStrings.Get("Plan/LabelTable"), relation);
        }

        if (node.CostRangeText(2) is { } cost)
        {
            Line(CoreStrings.Get("Plan/LabelCost"), cost);
        }

        if (node.EstimatedRows is { } rows)
        {
            Line(CoreStrings.Get("Plan/LabelRows"), rows.ToString(CultureInfo.InvariantCulture));
        }

        if (node.EstimatedWidth is { } width and > 0)
        {
            Line(CoreStrings.Get("Plan/LabelWidth"), width.ToString(CultureInfo.InvariantCulture));
        }

        if (node.ActualTotalTime is { } time)
        {
            Line(CoreStrings.Get("Plan/LabelActualTime"), Milliseconds(time));
        }

        if (node.ActualRows is { } actualRows)
        {
            Line(CoreStrings.Get("Plan/LabelActualRows"), actualRows.ToString(CultureInfo.InvariantCulture));
        }

        if (node.ActualLoops is { } loops and > 1)
        {
            Line(CoreStrings.Get("Plan/LabelLoops"), loops.ToString(CultureInfo.InvariantCulture));
        }

        foreach (var (key, value) in VisibleProperties(node))
        {
            Line(key, value);
        }

        foreach (var warning in node.Warnings)
        {
            Line(CoreStrings.Get("Plan/LabelWarning"), warning);
        }

        foreach (var index in node.MissingIndexes)
        {
            Line(CoreStrings.Get("Plan/LabelMissingIndex"), index.CreateStatement);
        }

        return text.ToString();
    }

    /// <summary>One spoken sentence: what the node does, on what, and how expensive it is.</summary>
    public static string AccessibleName(QueryPlanNode node)
    {
        ArgumentNullException.ThrowIfNull(node);
        var parts = new List<string>(6) { node.Operation };
        if (node.Relation is { } relation)
        {
            parts.Add(CoreStrings.Format("Plan/AccessibleOnRelation", relation));
        }

        if (node.Severity is { } severity)
        {
            parts.Add(severity.Label());
        }

        if (node.Warnings.Count > 0)
        {
            parts.Add(WarningCount(node.Warnings.Count));
        }

        if (node.CostRangeText(2) is { } cost)
        {
            parts.Add(CoreStrings.Format("Plan/AccessibleCost", cost));
        }

        if (node.EstimatedRows is { } rows)
        {
            parts.Add(CoreStrings.Plural("Plan/AccessibleRows", rows));
        }

        if (node.ActualTotalTime is { } time)
        {
            parts.Add(CoreStrings.Format("Plan/AccessibleActualTime", Milliseconds(time)));
        }

        return string.Join(CoreStrings.Get("Plan/AccessibleSeparator"), parts);
    }

    public static string WarningCount(int count) => CoreStrings.Plural("Plan/AccessibleWarnings", count);

    private static bool IsVisible(string key, string value) =>
        !HiddenPropertyKeys.Contains(key) && (SignificantZeroKeys.Contains(key) || (value != "false" && value != "0"));
}
