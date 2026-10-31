namespace TablePro.Core.Plans;

/// <summary>A parsed plan: the tree, the plan-wide timings, and the text the server returned.</summary>
public sealed class QueryPlan
{
    public QueryPlan(QueryPlanNode root, string rawText, PlanFormat format, double? planningTime = null, double? executionTime = null)
    {
        ArgumentNullException.ThrowIfNull(root);
        Root = root;
        RawText = rawText;
        Format = format;
        PlanningTime = planningTime;
        ExecutionTime = executionTime;
    }

    public QueryPlanNode Root { get; }

    public string RawText { get; }

    public PlanFormat Format { get; }

    /// <summary>Milliseconds.</summary>
    public double? PlanningTime { get; }

    /// <summary>Milliseconds.</summary>
    public double? ExecutionTime { get; }

    /// <summary>Every node, parents before children, in the order the plan lists them.</summary>
    public IEnumerable<QueryPlanNode> Nodes
    {
        get
        {
            var stack = new Stack<QueryPlanNode>();
            stack.Push(Root);
            while (stack.TryPop(out var node))
            {
                yield return node;
                for (var i = node.Children.Count - 1; i >= 0; i--)
                {
                    stack.Push(node.Children[i]);
                }
            }
        }
    }

    public int NodeCount => Nodes.Count();

    /// <summary>Whether any node satisfies a predicate, for deciding what there is to show.</summary>
    public bool Contains(Func<QueryPlanNode, bool> predicate)
    {
        ArgumentNullException.ThrowIfNull(predicate);
        foreach (var node in Nodes)
        {
            if (predicate(node))
            {
                return true;
            }
        }

        return false;
    }

    /// <summary>
    /// Sets each node's share of the plan's total work. The denominator is the sum of every node's exclusive cost,
    /// not the root's total: PostgreSQL prices a Limit far below its child on purpose, so dividing by the root gave
    /// shares above 1 (5.6 on a plain <c>ORDER BY ... LIMIT 2</c>). Exclusive costs sum to the real total, so a share
    /// of it is bounded and the shares add up to 1. A plan that reports no cost leaves every fraction null.
    /// </summary>
    internal void ComputeCostFractions()
    {
        var total = 0d;
        foreach (var node in Nodes)
        {
            total += node.ExclusiveCost;
        }

        if (total <= 0)
        {
            return;
        }

        foreach (var node in Nodes)
        {
            node.CostFraction = node.ExclusiveCost / total;
        }
    }
}
