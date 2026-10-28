namespace TablePro.Core.Plans;

/// <summary>How expensive a plan node is relative to the whole plan, so every plan view grades a node the same way.</summary>
public enum QueryPlanSeverity
{
    Low,
    Moderate,
    High,
    Critical,
}

public static class QueryPlanSeverities
{
    /// <summary>
    /// A share is a node's part of a plan-wide total, so it belongs in 0 to 1. A value outside that range means the
    /// caller divided by the wrong thing, and the clamp keeps the badge readable rather than pinning every node to
    /// critical; a non-finite share is treated as cheap rather than trusted.
    /// </summary>
    public static QueryPlanSeverity ForShare(double share)
    {
        if (!double.IsFinite(share))
        {
            return QueryPlanSeverity.Low;
        }

        var bounded = Math.Clamp(share, 0, 1);
        return bounded switch
        {
            > 0.5 => QueryPlanSeverity.Critical,
            > 0.2 => QueryPlanSeverity.High,
            > 0.05 => QueryPlanSeverity.Moderate,
            _ => QueryPlanSeverity.Low,
        };
    }

    /// <summary>What a screen reader says for the badge, since the glyph and colour carry the meaning visually.</summary>
    public static string Label(this QueryPlanSeverity severity) => severity switch
    {
        QueryPlanSeverity.Low => "Low cost",
        QueryPlanSeverity.Moderate => "Moderate cost",
        QueryPlanSeverity.High => "High cost",
        _ => "Critical cost",
    };
}
