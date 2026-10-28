using System.Globalization;

namespace TablePro.Core.Plans.Parsers;

/// <summary>
/// SQLite <c>EXPLAIN QUERY PLAN</c> rows (id, parent, notused, detail), shared by every engine that speaks SQLite's
/// dialect. SQLite reports no cost, so these plans carry structure only.
/// </summary>
public static class SqlitePlanParser
{
    private const int MaximumDepth = 256;

    public static QueryPlan? Parse(string rawText)
    {
        ArgumentNullException.ThrowIfNull(rawText);
        var rows = new List<(long Id, long Parent, string Detail)>();
        foreach (var line in QueryPlanTreeBuilder.Lines(rawText))
        {
            if (line.Length == 0)
            {
                continue;
            }

            var parts = line.Split('\t');
            if (parts.Length >= 4
                && long.TryParse(parts[0].Trim(), NumberStyles.Integer, CultureInfo.InvariantCulture, out var id)
                && long.TryParse(parts[1].Trim(), NumberStyles.Integer, CultureInfo.InvariantCulture, out var parent))
            {
                rows.Add((id, parent, parts[3].Trim()));
            }
            else
            {
                // A line that is not four columns still says something, so it becomes a flat step.
                rows.Add((rows.Count, -1, line));
            }
        }

        if (rows.Count == 0)
        {
            return null;
        }

        var byParent = rows.ToLookup(r => r.Parent);
        List<QueryPlanNode> Build(long parent, int depth) =>
            depth >= MaximumDepth
                ? []
                : byParent[parent].Where(r => r.Id != parent)
                    .Select(r => new QueryPlanNode { Operation = r.Detail, Children = Build(r.Id, depth + 1) })
                    .ToList();

        var root = QueryPlanTreeBuilder.Root(Build(rows.Min(r => r.Parent), 0));
        return root is null ? null : new QueryPlan(root, rawText, PlanFormat.SqliteQueryPlan);
    }
}

/// <summary>A tree drawn by leading whitespace, as ClickHouse prints its EXPLAIN.</summary>
public static class IndentedTextPlanParser
{
    public static QueryPlan? Parse(string rawText)
    {
        ArgumentNullException.ThrowIfNull(rawText);
        var lines = new List<(int Indent, string Text)>();
        foreach (var line in QueryPlanTreeBuilder.Lines(rawText))
        {
            if (line.Length == 0)
            {
                continue;
            }

            var text = line.TrimStart(' ', '\t');
            lines.Add((line.Length - text.Length, text));
        }

        var roots = QueryPlanTreeBuilder.Forest(lines, l => l.Indent, (l, children) => new QueryPlanNode { Operation = l.Text, Children = children });
        var root = QueryPlanTreeBuilder.Root(roots);
        return root is null ? null : new QueryPlan(root, rawText, PlanFormat.IndentedText);
    }
}

/// <summary>DM8 plans, whose hierarchy is the column the <c>#</c> marker sits in after the line number.</summary>
public static class DamengPlanParser
{
    public static QueryPlan? Parse(string rawText)
    {
        ArgumentNullException.ThrowIfNull(rawText);
        var lines = new List<(int Indent, string Operation, string? Details)>();
        foreach (var line in rawText.Split('\n', '\r'))
        {
            if (ParseLine(line) is { } parsed)
            {
                lines.Add(parsed);
            }
        }

        var roots = QueryPlanTreeBuilder.Forest(lines, l => l.Indent, (l, children) => new QueryPlanNode
        {
            Operation = l.Operation,
            Properties = l.Details is null ? new Dictionary<string, string>(0) : new Dictionary<string, string>(StringComparer.Ordinal) { ["Details"] = l.Details },
            Children = children,
        });
        var root = QueryPlanTreeBuilder.Root(roots);
        return root is null ? null : new QueryPlan(root, rawText, PlanFormat.DamengText);
    }

    private static (int Indent, string Operation, string? Details)? ParseLine(string line)
    {
        var i = 0;
        while (i < line.Length && line[i] is ' ' or '\t')
        {
            i++;
        }

        var numberStart = i;
        while (i < line.Length && char.IsDigit(line[i]))
        {
            i++;
        }

        if (i == numberStart)
        {
            return null;
        }

        while (i < line.Length && line[i] is ' ' or '\t')
        {
            i++;
        }

        if (i >= line.Length || line[i] != '#')
        {
            return null;
        }

        var markerColumn = i;
        var planText = line[(i + 1)..];
        var colon = planText.IndexOf(':', StringComparison.Ordinal);
        var operation = (colon < 0 ? planText : planText[..colon]).Trim();
        if (operation.Length == 0)
        {
            return null;
        }

        var details = colon < 0 ? null : planText[(colon + 1)..].Trim();
        return (markerColumn, operation, string.IsNullOrEmpty(details) ? null : details);
    }
}

/// <summary>
/// CockroachDB <c>EXPLAIN</c> and <c>EXPLAIN ANALYZE</c> text: a <c>•</c> per node, tree-drawing characters, and
/// <c>key: value</c> lines under each node.
/// </summary>
public static class CockroachDbPlanParser
{
    private static readonly char[] TreeDecoration = [' ', '\t', '│', '├', '└', '─'];

    public static QueryPlan? Parse(string rawText)
    {
        ArgumentNullException.ThrowIfNull(rawText);
        double? planning = null, execution = null;
        var nodes = new List<(int Depth, string Operation, Dictionary<string, string> Properties)>();

        foreach (var line in QueryPlanTreeBuilder.Lines(rawText))
        {
            var bullet = line.IndexOf('•', StringComparison.Ordinal);
            if (bullet < 0)
            {
                var trimmed = line.Trim(TreeDecoration);
                if (trimmed.Length == 0 || KeyValue(trimmed) is not { } pair)
                {
                    continue;
                }

                switch (pair.Key)
                {
                    case "planning time":
                        planning = Milliseconds(pair.Value);
                        break;
                    case "execution time":
                        execution = Milliseconds(pair.Value);
                        break;
                    default:
                        if (nodes.Count > 0)
                        {
                            nodes[^1].Properties[pair.Key] = pair.Value;
                        }

                        break;
                }

                continue;
            }

            nodes.Add((bullet, line[(bullet + 1)..].Trim(), new Dictionary<string, string>(StringComparer.Ordinal)));
        }

        var roots = QueryPlanTreeBuilder.Forest(nodes, n => n.Depth, (n, children) => MakeNode(n.Operation, n.Properties, children));
        var root = QueryPlanTreeBuilder.Root(roots);
        return root is null ? null : new QueryPlan(root, rawText, PlanFormat.CockroachText, planning, execution);
    }

    private static QueryPlanNode MakeNode(string operation, Dictionary<string, string> raw, IReadOnlyList<QueryPlanNode> children)
    {
        var relation = raw.TryGetValue("table", out var table) ? table.Split('@')[0] : null;
        var properties = new Dictionary<string, string>(StringComparer.Ordinal);
        foreach (var (key, value) in raw)
        {
            if (key is not ("estimated row count" or "actual row count" or "table"))
            {
                properties[key] = value;
            }
        }

        return new QueryPlanNode
        {
            Operation = operation.Length == 0 ? "Unknown" : operation,
            Relation = relation,
            EstimatedRows = RowCount(raw.GetValueOrDefault("estimated row count")),
            ActualRows = RowCount(raw.GetValueOrDefault("actual row count")),
            Properties = properties,
            Children = children,
        };
    }

    private static (string Key, string Value)? KeyValue(string line)
    {
        var separator = line.IndexOf(": ", StringComparison.Ordinal);
        if (separator < 0)
        {
            return null;
        }

        var key = line[..separator].Trim().ToLowerInvariant();
        return key.Length == 0 ? null : (key, line[(separator + 2)..].Trim());
    }

    /// <summary>"1,000 (100% of the table)" is a thousand rows.</summary>
    private static long? RowCount(string? value)
    {
        if (value is null)
        {
            return null;
        }

        var digits = new string(value.TakeWhile(c => char.IsDigit(c) || c == ',').Where(c => c != ',').ToArray());
        return long.TryParse(digits, NumberStyles.Integer, CultureInfo.InvariantCulture, out var count) ? count : null;
    }

    private static double? Milliseconds(string value)
    {
        var trimmed = value.Trim();
        var length = 0;
        while (length < trimmed.Length && (char.IsDigit(trimmed[length]) || trimmed[length] == '.'))
        {
            length++;
        }

        if (!double.TryParse(trimmed.AsSpan(0, length), NumberStyles.Float, CultureInfo.InvariantCulture, out var number))
        {
            return null;
        }

        return trimmed[length..].Trim().ToLowerInvariant() switch
        {
            "s" => number * 1_000,
            "µs" or "us" => number / 1_000,
            _ => number,
        };
    }
}
