using System.Globalization;
using CommunityToolkit.Mvvm.ComponentModel;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Media;
using TablePro.App.Helpers;
using TablePro.Core.Plans;

namespace TablePro.App.Controls;

/// <summary>
/// Which outline columns a plan can fill, shared by every row and the header so they line up. A plan that reports none
/// of a column's values shows no column rather than a blank one: SQLite, ClickHouse and DuckDB report no cost at all.
/// </summary>
public sealed class QueryPlanColumns
{
    private static readonly GridLength Hidden = new(0);

    public QueryPlanColumns(QueryPlan plan, bool hasMagnitude)
    {
        MagnitudeWidth = hasMagnitude ? new GridLength(200) : Hidden;
        CostWidth = plan.Contains(n => n.EstimatedTotalCost is not null) ? new GridLength(110) : Hidden;
        var measured = plan.Contains(n => n.ActualRows is not null);
        RowsWidth = measured || plan.Contains(n => n.EstimatedRows is not null) ? new GridLength(measured ? 160 : 100) : Hidden;
        TimeWidth = plan.Contains(n => n.ActualTotalTime is not null) ? new GridLength(90) : Hidden;
    }

    public GridLength MagnitudeWidth { get; }

    public GridLength CostWidth { get; }

    public GridLength RowsWidth { get; }

    public GridLength TimeWidth { get; }
}

/// <summary>One plan step in the outline: the node, its formatted columns, and its bar for the chosen metric.</summary>
public sealed partial class QueryPlanRow : ObservableObject
{
    // A step that did a thousandth of the largest step's work still did some, so its bar never rounds away.
    private const double MinimumVisibleFraction = 0.015;

    private readonly FrameworkElement _theme;

    public QueryPlanRow(QueryPlanNode node, QueryPlanRow? parent, QueryPlanColumns columns, FrameworkElement theme)
    {
        Node = node;
        Parent = parent;
        Columns = columns;
        _theme = theme;
        IsExpanded = true;
        Children = node.Children.Select(child => new QueryPlanRow(child, this, columns, theme)).ToList();
        if (node.Severity is { } severity)
        {
            SeverityGlyph = QueryPlanStyles.Glyph(severity);
            SeverityBrush = QueryPlanStyles.Foreground(theme, severity);
            SeverityLabel = PlanNames.Label(severity);
        }
    }

    internal QueryPlanNode Node { get; }

    public QueryPlanRow? Parent { get; }

    public QueryPlanColumns Columns { get; }

    public IList<QueryPlanRow> Children { get; }

    public string Operation => Node.Operation;

    /// <summary>What the step reads: the table, or the index when the engine names only that.</summary>
    public string Target => Node.Relation ?? Node.Properties.GetValueOrDefault("Index Name") ?? string.Empty;

    public string CostText => Node.CostRangeText(2) ?? string.Empty;

    public string RowsText => (Node.ActualRows, Node.EstimatedRows) switch
    {
        ({ } actual, { } estimated) => string.Create(CultureInfo.CurrentCulture, $"{actual:N0} / {estimated:N0}"),
        ({ } actual, null) => actual.ToString("N0", CultureInfo.CurrentCulture),
        (null, { } estimated) => estimated.ToString("N0", CultureInfo.CurrentCulture),
        _ => string.Empty,
    };

    public string TimeText => Node.ActualTotalTime is { } time ? QueryPlanValueFormatter.Compact(time, QueryPlanUnit.Milliseconds) : string.Empty;

    public string SeverityGlyph { get; } = string.Empty;

    public Brush? SeverityBrush { get; }

    public string SeverityLabel { get; } = string.Empty;

    public bool HasSeverity => Node.Severity is not null;

    public bool HasWarnings => Node.Warnings.Count > 0 || Node.MissingIndexes.Count > 0;

    public string WarningText => (Node.Warnings.Count + Node.MissingIndexes.Count).ToString(CultureInfo.CurrentCulture);

    public string AccessibleName => PlanNames.AccessibleName(Node);

    [ObservableProperty]
    public partial bool IsExpanded { get; set; }

    [ObservableProperty]
    public partial GridLength BarFill { get; set; }

    [ObservableProperty]
    public partial GridLength BarRest { get; set; }

    [ObservableProperty]
    public partial Brush? BarBrush { get; set; }

    [ObservableProperty]
    public partial string BarText { get; set; } = string.Empty;

    [ObservableProperty]
    public partial bool HasBar { get; set; }

    /// <summary>Points the bar at a metric. A row metric has no severity and takes the accent, which is not "missing".</summary>
    public void ApplyMetric(QueryPlanMetricIndex? index)
    {
        if (index?.Fraction(Node) is not { } fraction || index.Value(Node) is not { } value)
        {
            HasBar = false;
            BarText = string.Empty;
            BarFill = new GridLength(0, GridUnitType.Star);
            BarRest = new GridLength(1, GridUnitType.Star);
        }
        else
        {
            var shown = fraction > 0 ? Math.Max(fraction, MinimumVisibleFraction) : 0;
            HasBar = true;
            BarFill = new GridLength(shown, GridUnitType.Star);
            BarRest = new GridLength(1 - shown, GridUnitType.Star);
            BarText = QueryPlanValueFormatter.Compact(value, index.Metric.Unit());
            BarBrush = index.Severity(Node) is { } severity
                ? QueryPlanStyles.Foreground(_theme, severity)
                : ThemeResources.Brush(_theme, "AccentFillColorDefaultBrush");
        }

        foreach (var child in Children)
        {
            child.ApplyMetric(index);
        }
    }

    public IEnumerable<QueryPlanRow> SelfAndDescendants()
    {
        yield return this;
        foreach (var child in Children)
        {
            foreach (var row in child.SelfAndDescendants())
            {
                yield return row;
            }
        }
    }
}
