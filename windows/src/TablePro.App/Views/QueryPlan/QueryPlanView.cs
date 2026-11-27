using Microsoft.UI;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using TablePro.App.Model;
using TablePro.App.Services;
using TablePro.Interop;

namespace TablePro.App.Views;

// A parsed EXPLAIN plan as a tree of nodes with a per-metric magnitude bar, or the engine's raw output. Diagram and
// Compare modes are macOS's and not ported yet (ROADMAP S-17).
internal sealed partial class QueryPlanView : UserControl
{
    private const double BarWidth = 140;
    private const double IndentStep = 16;

    private readonly SelectorBar _modes = new() { Margin = new Thickness(4, 0, 4, 0) };
    private readonly SelectorBarItem _treeItem = new() { IsSelected = true };
    private readonly SelectorBarItem _rawItem = new();
    private readonly ComboBox _metric = new()
    {
        MinWidth = 120,
        VerticalAlignment = VerticalAlignment.Center,
        Visibility = Visibility.Collapsed,
    };

    private readonly TextBlock _summary = new()
    {
        VerticalAlignment = VerticalAlignment.Center,
        TextTrimming = TextTrimming.CharacterEllipsis,
    };

    private readonly StackPanel _rows = new() { Margin = new Thickness(0, 0, 0, 8) };
    private readonly ScrollViewer _tree;

    private readonly TextBox _raw = new()
    {
        Margin = new Thickness(8, 0, 8, 8),
        IsReadOnly = true,
        AcceptsReturn = true,
        IsSpellCheckEnabled = false,
        FontFamily = new FontFamily("Cascadia Mono, Consolas, Courier New"),
    };

    private QueryPlan? _plan;

    public QueryPlanView()
    {
        _treeItem.Text = Strings.Get("PlanTreeMode");
        _rawItem.Text = Strings.Get("PlanRawMode");
        AutomationProperties.SetAutomationId(_treeItem, "PlanTreeMode");
        AutomationProperties.SetAutomationId(_rawItem, "PlanRawMode");
        AutomationProperties.SetAutomationId(_modes, "PlanModes");
        AutomationProperties.SetName(_modes, Strings.Get("PlanModes"));
        _modes.Items.Add(_treeItem);
        _modes.Items.Add(_rawItem);
        _modes.SelectionChanged += (_, _) => ShowMode();

        AutomationProperties.SetAutomationId(_metric, "PlanMetric");
        AutomationProperties.SetName(_metric, Strings.Get("PlanMetricName"));
        _metric.SelectionChanged += (_, _) => BuildTree();

        _summary.Style = (Style)Application.Current.Resources["SecondaryCaptionTextBlockStyle"];
        AutomationProperties.SetAutomationId(_summary, "PlanSummary");
        AutomationProperties.SetLiveSetting(_summary, Microsoft.UI.Xaml.Automation.Peers.AutomationLiveSetting.Polite);

        ScrollViewer.SetVerticalScrollBarVisibility(_raw, ScrollBarVisibility.Auto);
        _raw.TextWrapping = TextWrapping.NoWrap;
        ScrollViewer.SetHorizontalScrollBarVisibility(_raw, ScrollBarVisibility.Auto);
        AutomationProperties.SetAutomationId(_raw, "PlanRaw");
        AutomationProperties.SetName(_raw, Strings.Get("PlanRawName"));

        _tree = new ScrollViewer
        {
            Margin = new Thickness(4, 0, 4, 0),
            HorizontalScrollMode = ScrollMode.Auto,
            HorizontalScrollBarVisibility = ScrollBarVisibility.Auto,
            Content = _rows,
        };
        AutomationProperties.SetAutomationId(_tree, "PlanTree");
        AutomationProperties.SetName(_tree, Strings.Get("PlanTreeName"));

        var bar = new Grid { ColumnSpacing = 12, Padding = new Thickness(0, 4, 8, 4) };
        bar.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        bar.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        bar.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        Grid.SetColumn(_metric, 1);
        Grid.SetColumn(_summary, 2);
        bar.Children.Add(_modes);
        bar.Children.Add(_metric);
        bar.Children.Add(_summary);

        var root = new Grid();
        root.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        root.RowDefinitions.Add(new RowDefinition { Height = new GridLength(1, GridUnitType.Star) });
        Grid.SetRow(_tree, 1);
        Grid.SetRow(_raw, 1);
        root.Children.Add(bar);
        root.Children.Add(_tree);
        root.Children.Add(_raw);
        Content = root;
    }

    // For the Edit menu's Copy and Select All while the raw text shows.
    internal TextBox? ShownText => ShowsTree ? null : _raw;

    private bool ShowsTree => ReferenceEquals(_modes.SelectedItem, _treeItem);

    // A null plan means the format had no parser or the text did not parse: only the raw output is shown.
    public void Show(QueryPlan? plan, string rawText)
    {
        ArgumentNullException.ThrowIfNull(rawText);
        _plan = plan;
        _raw.Text = rawText;
        _treeItem.IsEnabled = plan is not null;
        _summary.Text = plan is null ? string.Empty : SummaryText(plan);
        _summary.Visibility = _summary.Text.Length > 0 ? Visibility.Visible : Visibility.Collapsed;
        FillMetrics(plan);
        _modes.SelectedItem = plan is null ? _rawItem : _treeItem;
        ShowMode();
    }

    public void Clear()
    {
        _plan = null;
        _rows.Children.Clear();
        _raw.Text = string.Empty;
        _summary.Text = string.Empty;
    }

    private void FillMetrics(QueryPlan? plan)
    {
        _metric.Items.Clear();
        if (plan is null)
        {
            return;
        }

        foreach (var metric in QueryPlanRows.MetricsFor(plan))
        {
            _metric.Items.Add(new ComboBoxItem { Content = MetricLabel(metric), Tag = metric });
        }

        if (_metric.Items.Count > 0)
        {
            _metric.SelectedIndex = 0;
        }
    }

    private void ShowMode()
    {
        var tree = ShowsTree;
        _tree.Visibility = tree ? Visibility.Visible : Visibility.Collapsed;
        _raw.Visibility = tree ? Visibility.Collapsed : Visibility.Visible;
        _metric.Visibility = tree && _metric.Items.Count > 1 ? Visibility.Visible : Visibility.Collapsed;
        if (tree)
        {
            BuildTree();
        }
    }

    private void BuildTree()
    {
        _rows.Children.Clear();
        if (_plan is not { } plan)
        {
            return;
        }

        var metric = _metric.SelectedItem is ComboBoxItem { Tag: PlanMetric chosen } ? chosen : PlanMetric.Cost;
        foreach (var row in QueryPlanRows.Flatten(plan, metric))
        {
            _rows.Children.Add(Row(row));
        }
    }

    private static Grid Row(QueryPlanRow row)
    {
        var grid = new Grid { Padding = new Thickness(8, 3, 8, 3), ColumnSpacing = 12 };
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(BarWidth) });

        var label = new StackPanel
        {
            Orientation = Orientation.Horizontal,
            Spacing = 6,
            VerticalAlignment = VerticalAlignment.Center,
            Margin = new Thickness(row.Depth * IndentStep, 0, 0, 0),
        };
        var operation = new TextBlock
        {
            Text = row.Node.Operation,
            FontWeight = Microsoft.UI.Text.FontWeights.SemiBold,
            TextTrimming = TextTrimming.CharacterEllipsis,
        };
        label.Children.Add(operation);
        if (row.Node.Relation is { Length: > 0 } relation)
        {
            label.Children.Add(new TextBlock
            {
                Text = relation,
                VerticalAlignment = VerticalAlignment.Center,
                Foreground = Brush("TextFillColorSecondaryBrush"),
                TextTrimming = TextTrimming.CharacterEllipsis,
            });
        }

        var metric = new TextBlock
        {
            Text = row.MetricText ?? string.Empty,
            HorizontalAlignment = HorizontalAlignment.Right,
            VerticalAlignment = VerticalAlignment.Center,
            Foreground = Brush("TextFillColorSecondaryBrush"),
        };

        var bar = Bar(row.Magnitude);
        Grid.SetColumn(metric, 1);
        Grid.SetColumn(bar, 2);
        grid.Children.Add(label);
        grid.Children.Add(metric);
        grid.Children.Add(bar);

        AutomationProperties.SetName(grid, row.MetricText is { } text
            ? $"{row.Node.Operation} {text}"
            : row.Node.Operation);
        if (Details(row.Node) is { Length: > 0 } details)
        {
            ToolTipService.SetToolTip(grid, details);
        }

        return grid;
    }

    // A faint track, with a filled portion sized to the node's magnitude; empty where the node carries no figure.
    private static Border Bar(double? magnitude)
    {
        var inner = new Grid();
        if (magnitude is { } value)
        {
            var filled = Math.Clamp(value, 0, 1);
            inner.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(filled, GridUnitType.Star) });
            inner.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1 - filled, GridUnitType.Star) });
            var fill = new Border { Background = Brush("AccentFillColorDefaultBrush"), CornerRadius = new CornerRadius(4) };
            inner.Children.Add(fill);
        }

        return new Border
        {
            Height = 8,
            VerticalAlignment = VerticalAlignment.Center,
            CornerRadius = new CornerRadius(4),
            Background = Brush("ControlFillColorSecondaryBrush"),
            Child = inner,
        };
    }

    private static string SummaryText(QueryPlan plan)
    {
        var parts = new List<string>(2);
        if (plan.PlanningTime is { } planning)
        {
            parts.Add(Strings.Format("PlanPlanningTime", planning));
        }

        if (plan.ExecutionTime is { } execution)
        {
            parts.Add(Strings.Format("PlanExecutionTime", execution));
        }

        return string.Join(" · ", parts);
    }

    private static string Details(QueryPlanNode node)
    {
        var lines = new List<string>();
        if (node.Schema is { Length: > 0 } schema)
        {
            lines.Add(Strings.Format("PlanDetailSchema", schema));
        }

        foreach (var (key, value) in node.Properties)
        {
            lines.Add($"{key}: {value}");
        }

        return string.Join('\n', lines);
    }

    private static string MetricLabel(PlanMetric metric) =>
        Strings.Get(metric == PlanMetric.Rows ? "PlanMetricRows" : "PlanMetricCost");

    private static Brush Brush(string key) =>
        Application.Current.Resources.TryGetValue(key, out var value) && value is Brush brush
            ? brush
            : new SolidColorBrush(Colors.Gray);
}
