using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using TablePro.Core.Plans;
using Windows.ApplicationModel.DataTransfer;

namespace TablePro.App.Controls;

/// <summary>
/// One EXPLAIN result: a diagram, an outline with cost bars and severity badges, the raw text the server returned, and
/// a comparison with the tab's previous plan. The diagram and the outline share one selection and one detail pane.
/// </summary>
public sealed partial class QueryPlanView : UserControl
{
    // Remembered across plans for the session, and honoured only when a plan reports that metric, so one SQLite plan
    // does not lose the metric chosen for PostgreSQL.
    private static QueryPlanBarMetric? _preferredMetric;
    private static string _preferredMode = nameof(DiagramMode);

    private readonly Dictionary<QueryPlanNode, QueryPlanRow> _rows = [];
    private QueryPlanCapture? _current;
    private QueryPlanCapture? _baseline;
    private IReadOnlyList<QueryPlanBarMetric> _metrics = [];
    private QueryPlanRow? _root;
    private bool _syncing;

    public QueryPlanView()
    {
        InitializeComponent();
        Diagram.NodeSelected += (_, node) => Select(node);
        ActualThemeChanged += (_, _) =>
        {
            if (_current is not null)
            {
                Show(_current, _baseline);
            }
        };
    }

    public void Show(QueryPlanCapture current, QueryPlanCapture? baseline)
    {
        ArgumentNullException.ThrowIfNull(current);
        _current = current;
        _baseline = baseline;
        _rows.Clear();
        RawText.Text = current.RawText.Replace("\n", "\r", StringComparison.Ordinal);
        Comparison.Show(baseline, current);

        var plan = current.Plan;
        UnparsedBar.IsOpen = plan is null;
        DiagramMode.Visibility = TreeMode.Visibility = plan is null ? Visibility.Collapsed : Visibility.Visible;
        CompareMode.Visibility = baseline is null ? Visibility.Collapsed : Visibility.Visible;
        Diagram.Plan = plan;
        Details.Node = null;

        if (plan is null)
        {
            Tree.ItemsSource = null;
            _metrics = [];
            Timings.Text = string.Empty;
            SelectMode(RawMode);
            return;
        }

        _metrics = QueryPlanMetricIndex.AvailableMetrics(plan);
        var metric = _preferredMetric is { } preferred && _metrics.Contains(preferred) ? preferred : QueryPlanMetricIndex.DefaultMetric(_metrics);
        var columns = new QueryPlanColumns(plan, metric is not null);
        _root = new QueryPlanRow(plan.Root, null, columns, this);
        foreach (var row in _root.SelfAndDescendants())
        {
            _rows[row.Node] = row;
        }

        MagnitudeHeaderColumn.Width = columns.MagnitudeWidth;
        CostHeaderColumn.Width = columns.CostWidth;
        RowsHeaderColumn.Width = columns.RowsWidth;
        TimeHeaderColumn.Width = columns.TimeWidth;
        RowsHeader.Text = plan.Contains(n => n.ActualRows is not null) ? Strings.Get("Plan/ActualEstimatedRowsHeader") : Strings.Get("Plan/EstimatedRowsHeader");

        _syncing = true;
        MetricBox.Items.Clear();
        foreach (var available in _metrics)
        {
            MetricBox.Items.Add(new ComboBoxItem { Content = PlanNames.Title(available), Tag = available });
        }

        MetricBox.SelectedIndex = metric is { } m ? _metrics.ToList().IndexOf(m) : -1;
        _syncing = false;
        ApplyMetric(metric);
        Tree.ItemsSource = new[] { _root };

        Timings.Text = Describe(current, plan);
        SelectMode(_preferredMode == TreeMode.Name ? TreeMode : _preferredMode == RawMode.Name ? RawMode : DiagramMode);
    }

    private static string Describe(QueryPlanCapture capture, QueryPlan plan)
    {
        var parts = new List<string>(4) { Strings.Plural("Plan/TimingsSteps", plan.NodeCount) };
        if (plan.Root.EstimatedTotalCost is { } cost)
        {
            parts.Add(Strings.Format("Plan/TimingsCost", QueryPlanValueFormatter.Format(cost, QueryPlanUnit.Cost)));
        }

        if (plan.PlanningTime is { } planning)
        {
            parts.Add(Strings.Format("Plan/TimingsPlanning", QueryPlanValueFormatter.Format(planning, QueryPlanUnit.Milliseconds)));
        }

        if (plan.ExecutionTime is { } execution)
        {
            parts.Add(Strings.Format("Plan/TimingsExecution", QueryPlanValueFormatter.Format(execution, QueryPlanUnit.Milliseconds)));
        }

        return Strings.Format(capture.Analyze ? "Plan/TimingsAnalyzed" : "Plan/TimingsEstimated", string.Join(" · ", parts));
    }

    private void ApplyMetric(QueryPlanBarMetric? metric)
    {
        var index = metric is { } m && _current?.Plan is { } plan ? QueryPlanMetricIndex.Create(m, plan) : null;
        MagnitudeHeader.Text = metric is { } shown ? PlanNames.Title(shown) : string.Empty;
        _root?.ApplyMetric(index);
    }

    private void SelectMode(SelectorBarItem mode)
    {
        if (ReferenceEquals(Modes.SelectedItem, mode))
        {
            UpdateMode();
        }
        else
        {
            Modes.SelectedItem = mode;
        }
    }

    private void OnModeChanged(SelectorBar sender, SelectorBarSelectionChangedEventArgs args)
    {
        // Compare is a step away from the plan rather than a way of reading it, so the next plan opens as before.
        if (sender.SelectedItem is { } item && item != CompareMode && _current?.Plan is not null)
        {
            _preferredMode = item.Name;
        }

        UpdateMode();
    }

    private void UpdateMode()
    {
        var mode = Modes.SelectedItem;
        var parsed = _current?.Plan is not null;
        var showsSteps = parsed && (mode == DiagramMode || mode == TreeMode);
        Diagram.Visibility = parsed && mode == DiagramMode ? Visibility.Visible : Visibility.Collapsed;
        TreeHost.Visibility = parsed && mode == TreeMode ? Visibility.Visible : Visibility.Collapsed;
        RawText.Visibility = mode == RawMode || !parsed && mode != CompareMode ? Visibility.Visible : Visibility.Collapsed;
        Comparison.Visibility = mode == CompareMode ? Visibility.Visible : Visibility.Collapsed;
        ZoomButtons.Visibility = Diagram.Visibility;
        MetricBox.Visibility = parsed && mode == TreeMode && _metrics.Count > 1 ? Visibility.Visible : Visibility.Collapsed;
        DetailHost.Visibility = Splitter.Visibility = showsSteps ? Visibility.Visible : Visibility.Collapsed;
        SplitterColumn.Width = new GridLength(showsSteps ? 8 : 0);
        DetailColumn.MinWidth = showsSteps ? 200 : 0;
        DetailColumn.Width = showsSteps ? new GridLength(Math.Max(DetailColumn.ActualWidth, 320)) : new GridLength(0);
    }

    private void OnMetricChanged(object sender, SelectionChangedEventArgs e)
    {
        if (_syncing || MetricBox.SelectedItem is not ComboBoxItem { Tag: QueryPlanBarMetric metric })
        {
            return;
        }

        _preferredMetric = metric;
        ApplyMetric(metric);
    }

    private void OnTreeSelectionChanged(TreeView sender, TreeViewSelectionChangedEventArgs args)
    {
        if (!_syncing && args.AddedItems.Count > 0 && RowOf(args.AddedItems[0]) is { } row)
        {
            Select(row.Node);
        }
    }

    private void OnTreeItemInvoked(TreeView sender, TreeViewItemInvokedEventArgs args)
    {
        if (RowOf(args.InvokedItem) is { } row)
        {
            Select(row.Node);
        }
    }

    /// <summary>A bound tree hands back the item itself, or the node wrapping it, depending on the event.</summary>
    private static QueryPlanRow? RowOf(object? item) => item switch
    {
        QueryPlanRow row => row,
        TreeViewNode { Content: QueryPlanRow row } => row,
        _ => null,
    };

    /// <summary>One selection for both views: the detail pane shows it, the diagram outlines it, the outline highlights it.</summary>
    private void Select(QueryPlanNode node)
    {
        Details.Node = node;
        Diagram.SelectedNode = node;
        if (_rows.TryGetValue(node, out var row) && !ReferenceEquals(Tree.SelectedItem, row))
        {
            for (var parent = row.Parent; parent is not null; parent = parent.Parent)
            {
                parent.IsExpanded = true;
            }

            _syncing = true;
            Tree.SelectedItem = row;
            _syncing = false;
        }
    }

    private void OnZoomIn(object sender, RoutedEventArgs e) => Diagram.ZoomBy(1.25f);

    private void OnZoomOut(object sender, RoutedEventArgs e) => Diagram.ZoomBy(0.8f);

    private void OnFit(object sender, RoutedEventArgs e) => Diagram.Fit();

    private void OnCopy(object sender, RoutedEventArgs e)
    {
        if (_current is null)
        {
            return;
        }

        var package = new DataPackage();
        package.SetText(_current.RawText);
        Clipboard.SetContent(package);
    }
}
