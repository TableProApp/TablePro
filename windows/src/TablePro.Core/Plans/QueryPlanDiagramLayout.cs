namespace TablePro.Core.Plans;

/// <summary>A rectangle in diagram coordinates, kept free of any UI framework so the layout can be tested.</summary>
public readonly record struct PlanRect(double X, double Y, double Width, double Height)
{
    public double Right => X + Width;

    public double Bottom => Y + Height;

    public double CenterX => X + (Width / 2);

    public double CenterY => Y + (Height / 2);
}

public readonly record struct PlanPoint(double X, double Y);

/// <summary>A positioned plan step.</summary>
public sealed record PlanDiagramNode(QueryPlanNode Node, PlanRect Rect, QueryPlanNode? Parent, int Depth);

/// <summary>
/// A parent-to-child connector as geometry rather than a drawn path, so the canvas and a test read the same arrows:
/// a cubic curve from the parent's bottom edge to the child's top edge, and a three-point head at the child.
/// </summary>
public sealed record PlanDiagramArrow(QueryPlanNode Child, PlanPoint Start, PlanPoint End, PlanPoint Control1, PlanPoint Control2, IReadOnlyList<PlanPoint> Head);

/// <summary>Sizes for the diagram, so the canvas and the layout agree on how tall a step's lines are.</summary>
public sealed record PlanDiagramMetrics
{
    public static PlanDiagramMetrics Default { get; } = new();

    public double NodeWidth { get; init; } = 220;

    public double NodeMinHeight { get; init; } = 52;

    public double HorizontalSpacing { get; init; } = 24;

    public double VerticalSpacing { get; init; } = 40;

    public double NodePadding { get; init; } = 8;

    public double TitleLineHeight { get; init; } = 20;

    public double DetailLineHeight { get; init; } = 16;

    public double ArrowHeadSize { get; init; } = 6;
}

/// <summary>
/// Geometry for the plan diagram, laid out as the macOS app does: one row per tree depth, each row as tall as its
/// tallest step, and every parent centred over its first and last child.
/// </summary>
public sealed class QueryPlanDiagramLayout
{
    private readonly PlanDiagramMetrics _metrics;
    private readonly double[] _rowTops;

    public QueryPlanDiagramLayout(QueryPlanNode root, PlanDiagramMetrics? metrics = null)
    {
        ArgumentNullException.ThrowIfNull(root);
        _metrics = metrics ?? PlanDiagramMetrics.Default;
        _rowTops = RowTops(root);
        var nodes = new List<PlanDiagramNode>();
        Position(root, 0, 0, null, nodes);
        Nodes = nodes;
        Arrows = BuildArrows(nodes);
        var maxX = nodes.Count == 0 ? 400 : nodes.Max(n => n.Rect.Right);
        var maxY = nodes.Count == 0 ? 300 : nodes.Max(n => n.Rect.Bottom);
        Width = maxX + (_metrics.HorizontalSpacing * 2);
        Height = maxY + (_metrics.VerticalSpacing * 2);
    }

    /// <summary>Parents before their children.</summary>
    public IReadOnlyList<PlanDiagramNode> Nodes { get; }

    public IReadOnlyList<PlanDiagramArrow> Arrows { get; }

    public double Width { get; }

    public double Height { get; }

    /// <summary>The step drawn last under a point, which is the one on top.</summary>
    public PlanDiagramNode? HitTest(double x, double y) =>
        Nodes.LastOrDefault(n => x >= n.Rect.X && x <= n.Rect.Right && y >= n.Rect.Y && y <= n.Rect.Bottom);

    /// <summary>How tall a step is, from the lines it will show: title, relation, estimates, and measured time.</summary>
    public static double NodeHeight(QueryPlanNode node, PlanDiagramMetrics? metrics = null)
    {
        ArgumentNullException.ThrowIfNull(node);
        metrics ??= PlanDiagramMetrics.Default;
        var height = metrics.TitleLineHeight;
        if (node.Relation is not null || node.Properties.ContainsKey("Index Name"))
        {
            height += metrics.DetailLineHeight;
        }

        if (node.EstimatedTotalCost is not null || node.EstimatedRows is not null)
        {
            height += metrics.DetailLineHeight;
        }

        if (node.ActualTotalTime is not null || node.ActualRows is not null)
        {
            height += metrics.DetailLineHeight;
        }

        return Math.Max(metrics.NodeMinHeight, height + (metrics.NodePadding * 2));
    }

    /// <summary>The top edge of every depth, stacked by the tallest step in each row so siblings never drift apart.</summary>
    private double[] RowTops(QueryPlanNode root)
    {
        var heights = new List<double>();
        var stack = new Stack<(QueryPlanNode Node, int Depth)>();
        stack.Push((root, 0));
        while (stack.TryPop(out var item))
        {
            var height = NodeHeight(item.Node, _metrics);
            if (item.Depth < heights.Count)
            {
                heights[item.Depth] = Math.Max(heights[item.Depth], height);
            }
            else
            {
                while (heights.Count < item.Depth)
                {
                    heights.Add(0);
                }

                heights.Add(height);
            }

            foreach (var child in item.Node.Children)
            {
                stack.Push((child, item.Depth + 1));
            }
        }

        var tops = new double[heights.Count];
        var top = _metrics.VerticalSpacing;
        for (var i = 0; i < heights.Count; i++)
        {
            tops[i] = top;
            top += heights[i] + _metrics.VerticalSpacing;
        }

        return tops;
    }

    /// <summary>Places a subtree starting at <paramref name="left"/> and returns how wide it came out.</summary>
    private double Position(QueryPlanNode node, int depth, double left, QueryPlanNode? parent, List<PlanDiagramNode> into)
    {
        var top = depth < _rowTops.Length ? _rowTops[depth] : _metrics.VerticalSpacing;
        var height = NodeHeight(node, _metrics);
        if (node.Children.Count == 0)
        {
            into.Add(new PlanDiagramNode(node, new PlanRect(left + _metrics.HorizontalSpacing, top, _metrics.NodeWidth, height), parent, depth));
            return _metrics.NodeWidth;
        }

        // The parent goes in before its children so the list stays parents-first; its rect is fixed once they are placed.
        var slot = into.Count;
        into.Add(null!);
        var x = left;
        var firstChildCenter = 0d;
        var lastChildCenter = 0d;
        var minX = double.MaxValue;
        var maxX = double.MinValue;
        for (var i = 0; i < node.Children.Count; i++)
        {
            var start = into.Count;
            var width = Position(node.Children[i], depth + 1, x, node, into);
            var childCenter = into[start].Rect.CenterX;
            if (i == 0)
            {
                firstChildCenter = childCenter;
            }

            lastChildCenter = childCenter;
            for (var j = start; j < into.Count; j++)
            {
                minX = Math.Min(minX, into[j].Rect.X);
                maxX = Math.Max(maxX, into[j].Rect.Right);
            }

            x += width + _metrics.HorizontalSpacing;
        }

        var center = (firstChildCenter + lastChildCenter) / 2;
        var rect = new PlanRect(center - (_metrics.NodeWidth / 2), top, _metrics.NodeWidth, height);
        into[slot] = new PlanDiagramNode(node, rect, parent, depth);
        return Math.Max(maxX, rect.Right) - Math.Min(minX, rect.X);
    }

    private List<PlanDiagramArrow> BuildArrows(List<PlanDiagramNode> nodes)
    {
        var byNode = nodes.ToDictionary(n => n.Node);
        var arrows = new List<PlanDiagramArrow>(Math.Max(0, nodes.Count - 1));
        var head = _metrics.ArrowHeadSize;
        foreach (var positioned in nodes)
        {
            if (positioned.Parent is null || !byNode.TryGetValue(positioned.Parent, out var parent))
            {
                continue;
            }

            var start = new PlanPoint(parent.Rect.CenterX, parent.Rect.Bottom);
            var end = new PlanPoint(positioned.Rect.CenterX, positioned.Rect.Y);
            var midY = (start.Y + end.Y) / 2;
            arrows.Add(new PlanDiagramArrow(
                positioned.Node,
                start,
                end,
                new PlanPoint(start.X, midY),
                new PlanPoint(end.X, midY),
                [end, new PlanPoint(end.X - head, end.Y - head), new PlanPoint(end.X + head, end.Y - head)]));
        }

        return arrows;
    }
}
