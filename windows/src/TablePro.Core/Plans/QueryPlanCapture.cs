namespace TablePro.Core.Plans;

/// <summary>
/// One plan run: what was explained, what the server returned, and the tree when the text could be read as one. The
/// raw text is kept either way, so a plan the app cannot parse still shows and still compares.
/// </summary>
public sealed record QueryPlanCapture(string Subject, string RawText, PlanFormat Format, bool Analyze, DateTimeOffset CapturedAt)
{
    public QueryPlan? Plan { get; init; }

    public static QueryPlanCapture Create(string subject, string rawText, PlanFormat format, bool analyze, DateTimeOffset capturedAt)
    {
        ArgumentNullException.ThrowIfNull(rawText);
        return new QueryPlanCapture(subject, rawText, format, analyze, capturedAt) { Plan = QueryPlanParser.Parse(rawText, format) };
    }
}

public enum PlanTextChangeKind
{
    Same,
    Removed,
    Added,
}

/// <summary>
/// A line diff of two plans' raw text, for when either side could not be read as a tree: a difference is still shown
/// as one rather than as two blocks the reader has to align by eye.
/// </summary>
public static class PlanTextDiff
{
    /// <summary>Plans past this many lines are compared side by side instead, since the table grows with the product of both.</summary>
    public const int MaximumLines = 4_000;

    public static IReadOnlyList<(PlanTextChangeKind Kind, string Line)>? Lines(string baseline, string current)
    {
        ArgumentNullException.ThrowIfNull(baseline);
        ArgumentNullException.ThrowIfNull(current);
        var before = Parsers.QueryPlanTreeBuilder.Lines(baseline.TrimEnd());
        var after = Parsers.QueryPlanTreeBuilder.Lines(current.TrimEnd());
        if ((long)before.Length * after.Length > (long)MaximumLines * MaximumLines / 4)
        {
            return null;
        }

        var lengths = new int[before.Length + 1, after.Length + 1];
        for (var i = before.Length - 1; i >= 0; i--)
        {
            for (var j = after.Length - 1; j >= 0; j--)
            {
                lengths[i, j] = before[i] == after[j] ? lengths[i + 1, j + 1] + 1 : Math.Max(lengths[i + 1, j], lengths[i, j + 1]);
            }
        }

        var lines = new List<(PlanTextChangeKind, string)>(Math.Max(before.Length, after.Length));
        int b = 0, a = 0;
        while (b < before.Length && a < after.Length)
        {
            if (before[b] == after[a])
            {
                lines.Add((PlanTextChangeKind.Same, after[a]));
                b++;
                a++;
            }
            else if (lengths[b + 1, a] >= lengths[b, a + 1])
            {
                lines.Add((PlanTextChangeKind.Removed, before[b++]));
            }
            else
            {
                lines.Add((PlanTextChangeKind.Added, after[a++]));
            }
        }

        while (b < before.Length)
        {
            lines.Add((PlanTextChangeKind.Removed, before[b++]));
        }

        while (a < after.Length)
        {
            lines.Add((PlanTextChangeKind.Added, after[a++]));
        }

        return lines;
    }
}
