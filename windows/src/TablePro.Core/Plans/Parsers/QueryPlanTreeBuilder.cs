namespace TablePro.Core.Plans.Parsers;

/// <summary>Tree assembly the text parsers share.</summary>
internal static class QueryPlanTreeBuilder
{
    /// <summary>
    /// Builds a forest from a pre-order list where each element carries its own depth: an element belongs to the
    /// closest preceding element with a smaller depth. Iterative, so a pathological text plan cannot exhaust the stack.
    /// </summary>
    public static List<QueryPlanNode> Forest<T>(IReadOnlyList<T> elements, Func<T, int> depth, Func<T, IReadOnlyList<QueryPlanNode>, QueryPlanNode> makeNode)
    {
        var roots = new List<QueryPlanNode>();
        var open = new Stack<(T Element, int Depth, List<QueryPlanNode> Children)>();

        void Close()
        {
            var (element, _, children) = open.Pop();
            var node = makeNode(element, children);
            (open.Count > 0 ? open.Peek().Children : roots).Add(node);
        }

        foreach (var element in elements)
        {
            var elementDepth = depth(element);
            while (open.Count > 0 && open.Peek().Depth >= elementDepth)
            {
                Close();
            }

            open.Push((element, elementDepth, []));
        }

        while (open.Count > 0)
        {
            Close();
        }

        return roots;
    }

    /// <summary>
    /// The single root, or several roots under one synthetic node whose cost is the sum of the roots that report one,
    /// so cost fractions stay relative to a real total.
    /// </summary>
    public static QueryPlanNode? Root(IReadOnlyList<QueryPlanNode> roots)
    {
        if (roots.Count == 1)
        {
            return roots[0];
        }

        if (roots.Count == 0)
        {
            return null;
        }

        double? cost = null;
        foreach (var root in roots)
        {
            if (root.EstimatedTotalCost is { } c)
            {
                cost = (cost ?? 0) + c;
            }
        }

        return new QueryPlanNode { Operation = "Query Plan", EstimatedTotalCost = cost, Children = [.. roots] };
    }

    public static QueryPlan Finish(QueryPlanNode root, string rawText, PlanFormat format, double? planningTime = null, double? executionTime = null)
    {
        var plan = new QueryPlan(root, rawText, format, planningTime, executionTime);
        plan.ComputeCostFractions();
        return plan;
    }

    /// <summary>Rounds half away from zero, and drops a value past the range of a count rather than overflowing.</summary>
    public static long? BoundedInteger(double value)
    {
        var rounded = Math.Round(value, MidpointRounding.AwayFromZero);
        return double.IsFinite(rounded) && rounded >= long.MinValue && rounded < long.MaxValue ? (long)rounded : null;
    }

    public static void SetIfPresent(Dictionary<string, string> properties, string key, string? value)
    {
        if (value is not null)
        {
            properties[key] = value;
        }
    }

    /// <summary>Text split into lines with any carriage return dropped, so CRLF and LF output read the same.</summary>
    public static string[] Lines(string text)
    {
        var lines = text.Split('\n');
        for (var i = 0; i < lines.Length; i++)
        {
            lines[i] = lines[i].TrimEnd('\r');
        }

        return lines;
    }
}
