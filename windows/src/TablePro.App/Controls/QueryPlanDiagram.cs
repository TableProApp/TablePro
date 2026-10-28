using System.Globalization;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Shapes;
using TablePro.App.Helpers;
using TablePro.Core.Plans;
using Windows.ApplicationModel.DataTransfer;
using Windows.Foundation;
using Path = Microsoft.UI.Xaml.Shapes.Path;

namespace TablePro.App.Controls;

/// <summary>
/// The plan as a diagram, laid out as the macOS app lays it out: one row per depth, parents centred over their
/// children, a curve from each parent to each child. Each step is a button, so it takes focus, answers Enter and is a
/// named element for screen readers; the canvas zooms with Ctrl+wheel and pinch.
/// </summary>
public sealed partial class QueryPlanDiagram : UserControl
{
    private const float MinZoom = 0.25f;
    private const float MaxZoom = 2f;
    private const float ReadableZoom = 0.6f;

    private readonly Canvas _canvas = new();
    private readonly ScrollViewer _scroller;
    private readonly Dictionary<QueryPlanNode, Button> _cards = [];
    private QueryPlan? _plan;
    private QueryPlanDiagramLayout? _layout;
    private QueryPlanNode? _selected;
    private bool _needsInitialFit;

    public QueryPlanDiagram()
    {
        _scroller = new ScrollViewer
        {
            Content = _canvas,
            ZoomMode = ZoomMode.Enabled,
            MinZoomFactor = MinZoom,
            MaxZoomFactor = MaxZoom,
            HorizontalScrollMode = ScrollMode.Enabled,
            HorizontalScrollBarVisibility = ScrollBarVisibility.Auto,
            VerticalScrollBarVisibility = ScrollBarVisibility.Auto,
        };
        AutomationProperties.SetName(_canvas, "Plan diagram");
        Content = _scroller;
        ActualThemeChanged += (_, _) => Build();

        // A diagram hidden behind another mode has no viewport yet, so the first fit waits until it is shown.
        _scroller.SizeChanged += (_, _) => FitInitially();
    }

    /// <summary>Raised when a step is clicked or invoked.</summary>
    public event EventHandler<QueryPlanNode>? NodeSelected;

    // Internal, like SelectedNode: the XAML type table reflects over a control's public properties and would try to
    // construct the plan types, whose required members it cannot set.
    internal QueryPlan? Plan
    {
        get => _plan;
        set
        {
            _plan = value;
            _selected = null;
            Build();
            _needsInitialFit = value is not null;
            DispatcherQueue.TryEnqueue(Microsoft.UI.Dispatching.DispatcherQueuePriority.Low, FitInitially);
        }
    }

    internal QueryPlanNode? SelectedNode
    {
        get => _selected;
        set
        {
            if (ReferenceEquals(_selected, value))
            {
                return;
            }

            var previous = _selected;
            _selected = value;
            Restyle(previous);
            Restyle(value);
            BringIntoView(value);
        }
    }

    public void ZoomBy(float factor) => _scroller.ChangeView(null, null, Math.Clamp(_scroller.ZoomFactor * factor, MinZoom, MaxZoom));

    /// <summary>Shrinks a plan wider or taller than the view to fit it, and never enlarges a small one past actual size.</summary>
    public void Fit()
    {
        if (_layout is null || _scroller.ViewportWidth <= 0)
        {
            return;
        }

        var zoom = (float)Math.Clamp(Math.Min(_scroller.ViewportWidth / _layout.Width, _scroller.ViewportHeight / _layout.Height), MinZoom, 1);
        _scroller.ChangeView(0, 0, zoom);
    }

    /// <summary>
    /// Opens a new plan scaled to show as much of it as stays readable: a wide plan shrinks, but never below the size
    /// at which a step's text can still be read, and a small one is never enlarged.
    /// </summary>
    private void FitInitially()
    {
        if (!_needsInitialFit || _layout is null || _scroller.ViewportWidth <= 0 || _scroller.ViewportHeight <= 0)
        {
            return;
        }

        _needsInitialFit = false;
        var zoom = (float)Math.Clamp(Math.Min(_scroller.ViewportWidth / _layout.Width, _scroller.ViewportHeight / _layout.Height), ReadableZoom, 1);
        _scroller.ChangeView(0, 0, zoom, disableAnimation: true);
    }

    private void Build()
    {
        _canvas.Children.Clear();
        _cards.Clear();
        _layout = null;
        if (_plan is null)
        {
            return;
        }

        var layout = new QueryPlanDiagramLayout(_plan.Root);
        _layout = layout;
        _canvas.Width = layout.Width;
        _canvas.Height = layout.Height;

        var arrowBrush = ThemeResources.Brush(this, "TextFillColorTertiaryBrush");
        foreach (var arrow in layout.Arrows)
        {
            var figure = new PathFigure { StartPoint = ToPoint(arrow.Start) };
            figure.Segments.Add(new BezierSegment { Point1 = ToPoint(arrow.Control1), Point2 = ToPoint(arrow.Control2), Point3 = ToPoint(arrow.End) });
            var geometry = new PathGeometry();
            geometry.Figures.Add(figure);
            _canvas.Children.Add(new Path { Data = geometry, Stroke = arrowBrush, StrokeThickness = 1 });

            var head = new PointCollection();
            foreach (var point in arrow.Head)
            {
                head.Add(ToPoint(point));
            }

            _canvas.Children.Add(new Polygon { Points = head, Fill = arrowBrush });
        }

        foreach (var positioned in layout.Nodes)
        {
            var card = Card(positioned);
            Canvas.SetLeft(card, positioned.Rect.X);
            Canvas.SetTop(card, positioned.Rect.Y);
            _canvas.Children.Add(card);
            _cards[positioned.Node] = card;
        }
    }

    private Button Card(PlanDiagramNode positioned)
    {
        var node = positioned.Node;
        var metrics = PlanDiagramMetrics.Default;
        var lines = new StackPanel();

        var title = new Grid { ColumnSpacing = 5, Height = metrics.TitleLineHeight };
        title.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        title.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        title.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        if (node.Severity is { } severity)
        {
            title.Children.Add(QueryPlanStyles.Badge(this, severity, 9));
        }

        var operation = QueryPlanStyles.Text(node.Operation, size: 13, strong: true);
        if (node.Properties.TryGetValue("Join Type", out var joinType))
        {
            operation.Inlines.Clear();
            operation.Inlines.Add(new Microsoft.UI.Xaml.Documents.Run { Text = node.Operation });
            operation.Inlines.Add(new Microsoft.UI.Xaml.Documents.Run { Text = "  " + joinType, FontSize = 11, FontWeight = Microsoft.UI.Text.FontWeights.Normal, Foreground = ThemeResources.Brush(this, "TextFillColorSecondaryBrush") });
        }

        Grid.SetColumn(operation, 1);
        title.Children.Add(operation);
        if (node.Warnings.Count + node.MissingIndexes.Count is var findings and > 0)
        {
            var warning = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 2 };
            warning.Children.Add(new FontIcon { Glyph = "", FontSize = 12, Foreground = ThemeResources.Brush(this, "SystemFillColorCautionBrush") });
            warning.Children.Add(QueryPlanStyles.Text(findings.ToString(CultureInfo.CurrentCulture), size: 11));
            ToolTipService.SetToolTip(warning, string.Join("\n", node.Warnings.Concat(node.MissingIndexes.Select(i => i.CreateStatement))));
            Grid.SetColumn(warning, 2);
            title.Children.Add(warning);
        }

        lines.Children.Add(title);
        if ((node.Relation ?? node.Properties.GetValueOrDefault("Index Name")) is { } target)
        {
            lines.Children.Add(Detail(target, "TextFillColorSecondaryBrush", mono: false));
        }

        if (node.EstimatedTotalCost is not null || node.EstimatedRows is not null)
        {
            var parts = new List<string>(2);
            if (node.CostRangeText(1) is { } cost)
            {
                parts.Add(cost);
            }

            if (node.EstimatedRows is { } rows)
            {
                parts.Add(rows == 1 ? "1 row" : rows.ToString("N0", CultureInfo.CurrentCulture) + " rows");
            }

            lines.Children.Add(Detail(string.Join("   ", parts), "TextFillColorTertiaryBrush", mono: true));
        }

        if (node.ActualTotalTime is not null || node.ActualRows is not null)
        {
            var parts = new List<string>(2);
            if (node.ActualTotalTime is { } time)
            {
                parts.Add(QueryPlanLabels.Milliseconds(time));
            }

            if (node.ActualRows is { } actualRows)
            {
                parts.Add("actual " + actualRows.ToString("N0", CultureInfo.CurrentCulture));
            }

            lines.Children.Add(Detail(string.Join("   ", parts), "TextFillColorSecondaryBrush", mono: true));
        }

        var card = new Button
        {
            Content = lines,
            Width = positioned.Rect.Width,
            Height = positioned.Rect.Height,
            Padding = new Thickness(metrics.NodePadding),
            HorizontalContentAlignment = HorizontalAlignment.Stretch,
            VerticalContentAlignment = VerticalAlignment.Top,
            CornerRadius = new CornerRadius(6),
            Tag = node,
        };
        AutomationProperties.SetName(card, QueryPlanLabels.AccessibleName(node));
        ToolTipService.SetToolTip(card, QueryPlanLabels.Text(node));
        card.Click += (_, _) => NodeSelected?.Invoke(this, node);
        card.ContextFlyout = ContextMenu(node);
        Paint(card, node);
        return card;
    }

    private TextBlock Detail(string text, string brushKey, bool mono)
    {
        var block = QueryPlanStyles.Text(text, brushKey, this, size: 11, mono: mono);
        block.Height = PlanDiagramMetrics.Default.DetailLineHeight;
        return block;
    }

    private static MenuFlyout ContextMenu(QueryPlanNode node)
    {
        var menu = new MenuFlyout();
        menu.Items.Add(CopyItem("Copy Operation", node.Operation));
        menu.Items.Add(CopyItem("Copy Step Details", QueryPlanLabels.Text(node)));
        return menu;
    }

    private static MenuFlyoutItem CopyItem(string text, string value)
    {
        var item = new MenuFlyoutItem { Text = text, Icon = new FontIcon { Glyph = "" } };
        item.Click += (_, _) =>
        {
            var package = new DataPackage();
            package.SetText(value);
            Clipboard.SetContent(package);
        };
        return item;
    }

    private void Restyle(QueryPlanNode? node)
    {
        if (node is not null && _cards.TryGetValue(node, out var card))
        {
            Paint(card, node);
        }
    }

    /// <summary>
    /// A step is tinted by its severity, outlined in its status colour, and outlined in the accent when selected. The
    /// border brushes are also set as the button's own pointer-over and pressed resources, so hovering keeps the outline.
    /// </summary>
    private void Paint(Button card, QueryPlanNode node)
    {
        var selected = ReferenceEquals(node, _selected);
        var background = node.Severity is { } severity ? QueryPlanStyles.Background(this, severity) : ThemeResources.Brush(this, "CardBackgroundFillColorDefaultBrush");
        var border = selected
            ? ThemeResources.Brush(this, "AccentFillColorDefaultBrush")
            : node.Severity is { } s ? QueryPlanStyles.Foreground(this, s) : ThemeResources.Brush(this, "CardStrokeColorDefaultBrush");
        card.Background = background;
        card.BorderBrush = border;
        card.BorderThickness = new Thickness(selected ? 2 : 1);
        card.Resources["ButtonBorderBrushPointerOver"] = border;
        card.Resources["ButtonBorderBrushPressed"] = border;
    }

    private void BringIntoView(QueryPlanNode? node)
    {
        if (node is not null && _cards.TryGetValue(node, out var card))
        {
            card.StartBringIntoView(new BringIntoViewOptions { AnimationDesired = true, VerticalAlignmentRatio = 0.3, HorizontalAlignmentRatio = 0.5 });
        }
    }

    private static Point ToPoint(PlanPoint point) => new(point.X, point.Y);
}
