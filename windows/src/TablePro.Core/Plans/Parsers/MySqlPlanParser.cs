using System.Globalization;
using System.Text;
using System.Text.Json;
using System.Text.RegularExpressions;
using TablePro.Core.Localization;

namespace TablePro.Core.Plans.Parsers;

/// <summary>
/// Reads MySQL and MariaDB plans: <c>EXPLAIN FORMAT=JSON</c> first, then the TREE text that <c>EXPLAIN ANALYZE</c> and
/// <c>EXPLAIN FORMAT=TREE</c> print.
/// </summary>
public static class MySqlPlanParser
{
    public const int MaximumInputBytes = 2_000_000;

    public static QueryPlan? Parse(string rawText)
    {
        ArgumentNullException.ThrowIfNull(rawText);
        if (Encoding.UTF8.GetByteCount(rawText) > MaximumInputBytes)
        {
            return null;
        }

        return MySqlJsonPlanParser.Parse(rawText) ?? MySqlTreePlanParser.Parse(rawText);
    }
}

/// <summary>
/// MySQL's flat <c>query_block</c> and MariaDB's nested one (query_block, filesort, temporary_table, nested_loop), with
/// the measured <c>r_</c> figures MariaDB's <c>ANALYZE FORMAT=JSON</c> adds beside each estimate.
/// </summary>
public static class MySqlJsonPlanParser
{
    public static QueryPlan? Parse(string rawText)
    {
        ArgumentNullException.ThrowIfNull(rawText);
        var trimmed = rawText.Trim();
        if (!trimmed.StartsWith('{'))
        {
            return null;
        }

        using var document = PlanJson.Parse(trimmed);
        if (document?.RootElement.Property("query_block") is not { ValueKind: JsonValueKind.Object } block)
        {
            return null;
        }

        var cost = block.Property("cost").Number() ?? block.Property("cost_info")?.Property("query_cost").Number();
        return QueryPlanTreeBuilder.Finish(ParseBlock(block, "Query Block", cost), rawText, PlanFormat.MySql, executionTime: block.Property("r_total_time_ms").Number());
    }

    private static QueryPlanNode ParseBlock(JsonElement block, string operation, double? cost)
    {
        var children = new List<QueryPlanNode>();
        if (block.Property("table") is { ValueKind: JsonValueKind.Object } table)
        {
            children.Add(ParseTable(table));
        }

        if (block.Property("nested_loop") is { ValueKind: JsonValueKind.Array } loop)
        {
            foreach (var item in loop.EnumerateArray())
            {
                if (ParseLoopItem(item) is { } step)
                {
                    children.Add(step);
                }
            }
        }

        // MariaDB: a filesort wraps the inner plan.
        if (block.Property("filesort") is { ValueKind: JsonValueKind.Object } filesort)
        {
            var sortKey = filesort.Property("sort_key").String();
            var inner = ParseBlock(filesort, sortKey is null ? "Sort" : $"Sort ({sortKey})", null);
            if (inner.Children.Count > 0)
            {
                children = [inner];
            }
        }

        // MariaDB: a temporary table wraps the nested loop.
        if (block.Property("temporary_table") is { ValueKind: JsonValueKind.Object } temporary)
        {
            var inner = ParseBlock(temporary, "Temporary Table", null);
            if (inner.Children.Count > 0)
            {
                children = [.. inner.Children];
            }
        }

        if (block.Property("ordering_operation") is { ValueKind: JsonValueKind.Object } ordering)
        {
            children.Add(ParseBlock(ordering, "Sort", null));
        }

        if (block.Property("grouping_operation") is { ValueKind: JsonValueKind.Object } grouping)
        {
            children.Add(ParseBlock(grouping, "Group", null));
        }

        var (loops, time) = Measured(block);
        return new QueryPlanNode
        {
            Operation = operation,
            EstimatedTotalCost = cost,
            ActualLoops = loops,
            ActualTotalTime = time,
            ActualRows = block.Property("r_output_rows").Integer(),
            Children = children,
        };
    }

    /// <summary>
    /// One step of a MariaDB nested loop: a table, a table read through a join buffer, or a table read back in sorted
    /// order after a filesort, which MariaDB writes as <c>read_sorted_file</c>.
    /// </summary>
    private static QueryPlanNode? ParseLoopItem(JsonElement item)
    {
        if (item.Property("table") is { ValueKind: JsonValueKind.Object } table)
        {
            return ParseTable(table);
        }

        if (item.Property("block-nl-join") is { ValueKind: JsonValueKind.Object } joined && joined.Property("table") is { ValueKind: JsonValueKind.Object } buffered)
        {
            return ParseTable(buffered);
        }

        if (item.Property("read_sorted_file") is { ValueKind: JsonValueKind.Object } sorted)
        {
            var inner = ParseBlock(sorted, "Read Sorted File", null);
            return inner.Children.Count == 1 ? inner.Children[0] : inner;
        }

        return null;
    }

    /// <summary>
    /// MariaDB's loop count and time for a step. Its <c>r_total_time_ms</c> covers every loop, and 11.x splits a table's
    /// time into <c>r_table_time_ms</c> and <c>r_other_time_ms</c>; the node keeps time per loop, as PostgreSQL reports it.
    /// </summary>
    private static (long? Loops, double? TimePerLoop) Measured(JsonElement element)
    {
        var loops = element.Property("r_loops").Integer();
        var total = element.Property("r_total_time_ms").Number();
        if (total is null && element.Property("r_table_time_ms").Number() is { } table)
        {
            total = table + (element.Property("r_other_time_ms").Number() ?? 0);
        }

        return (loops, total is { } time && loops is > 0 ? time / loops.Value : total);
    }

    /// <summary>
    /// MariaDB reports one <c>cost</c> per table, and those sum to the block's own cost. MySQL splits the same quantity
    /// into <c>read_cost</c> and <c>eval_cost</c>; taking the read half alone left every table short and the wrapper
    /// block, which does no work, absorbed the difference as the reddest node in the plan.
    /// </summary>
    private static double? TableCost(JsonElement table)
    {
        if (table.Property("cost") is { ValueKind: JsonValueKind.Number } mariaDb)
        {
            return mariaDb.GetDouble();
        }

        var costInfo = table.Property("cost_info");
        if (costInfo?.Property("read_cost").Number() is not { } read)
        {
            return null;
        }

        return read + (costInfo?.Property("eval_cost").Number() ?? 0);
    }

    private static QueryPlanNode ParseTable(JsonElement table)
    {
        var properties = new Dictionary<string, string>(StringComparer.Ordinal);
        QueryPlanTreeBuilder.SetIfPresent(properties, "Key", table.Property("key").String());
        if (table.Property("ref") is { ValueKind: JsonValueKind.Array } reference)
        {
            properties["Ref"] = string.Join(", ", reference.EnumerateArray().Select(r => r.Spell()));
        }

        QueryPlanTreeBuilder.SetIfPresent(properties, "Filter", table.Property("attached_condition").String());
        if (table.Property("filtered").Number() is { } filtered and < 100)
        {
            properties["Filtered"] = filtered.ToString("F0", CultureInfo.InvariantCulture) + "%";
        }

        if (table.Property("r_filtered").Number() is { } actualFiltered and < 100)
        {
            properties["Actual Filtered"] = actualFiltered.ToString("F0", CultureInfo.InvariantCulture) + "%";
        }

        var (loops, time) = Measured(table);
        return new QueryPlanNode
        {
            Operation = table.Property("access_type").String() ?? "ALL",
            Relation = table.Property("table_name").String(),
            EstimatedTotalCost = TableCost(table),
            EstimatedRows = table.Property("rows").Integer() ?? table.Property("rows_examined_per_scan").Integer() ?? table.Property("rows_produced_per_join").Integer(),

            // MariaDB's r_rows is already an average per loop.
            ActualRows = table.Property("r_rows").Integer(),
            ActualLoops = loops,
            ActualTotalTime = time,
            Properties = properties,
        };
    }
}

/// <summary>The TREE text: one node per <c>-&gt;</c> line, nested by indentation, with cost and ANALYZE metrics at the end.</summary>
public static partial class MySqlTreePlanParser
{
    private const int MaximumNodes = 10_000;
    private const int MaximumDepth = 128;
    private const string NumberPattern = @"[-+]?(?:\d+(?:\.\d*)?|\.\d+)(?:[eE][-+]?\d+)?";

    public static QueryPlan? Parse(string rawText)
    {
        ArgumentNullException.ThrowIfNull(rawText);
        var rawNodes = ParseRawNodes(rawText);
        if (rawNodes is null || rawNodes.Count == 0)
        {
            return null;
        }

        var roots = QueryPlanTreeBuilder.Forest(rawNodes, n => n.Depth, (n, children) => MakeNode(n.Text, children));
        if (QueryPlanTreeBuilder.Root(roots) is not { } root)
        {
            return null;
        }

        double? execution = null;
        foreach (var top in roots)
        {
            if (top.ActualTotalTime is { } time && time * (top.ActualLoops ?? 1) is var total && double.IsFinite(total))
            {
                execution = Math.Max(execution ?? total, total);
            }
        }

        return QueryPlanTreeBuilder.Finish(root, rawText, PlanFormat.MySql, executionTime: execution);
    }

    [GeneratedRegex(@"\s+\(actual time=(" + NumberPattern + @")\.\.(" + NumberPattern + @")\s+rows=(" + NumberPattern + @")\s+loops=(" + NumberPattern + @")\)\s*$", RegexOptions.CultureInvariant)]
    private static partial Regex ActualMetrics();

    [GeneratedRegex(@"\s+\(cost=(" + NumberPattern + @")\s+rows=(" + NumberPattern + @")\)\s*$", RegexOptions.CultureInvariant)]
    private static partial Regex CostMetrics();

    [GeneratedRegex(@"\s+\(never executed\)\s*$", RegexOptions.CultureInvariant | RegexOptions.IgnoreCase)]
    private static partial Regex NeverExecuted();

    /// <summary>
    /// A node starts at every <c>-&gt;</c> line, so every line in between belongs to the node above it: MySQL wraps
    /// the metrics group, and node text keeps any newline the query's own literals contain.
    /// </summary>
    private static List<(int Depth, string Text)>? ParseRawNodes(string rawText)
    {
        var nodes = new List<(int Depth, string Text)>();
        var indents = new List<int>();
        (int Indent, string Text)? pending = null;

        bool AppendPending()
        {
            if (pending is not { } current)
            {
                return true;
            }

            while (indents.Count > 0 && current.Indent <= indents[^1])
            {
                indents.RemoveAt(indents.Count - 1);
            }

            if (indents.Count >= MaximumDepth || nodes.Count >= MaximumNodes)
            {
                return false;
            }

            indents.Add(current.Indent);
            nodes.Add((indents.Count - 1, current.Text));
            return true;
        }

        foreach (var line in rawText.Split('\n', '\r'))
        {
            if (NodeLine(line) is { } nodeLine)
            {
                if (!AppendPending())
                {
                    return null;
                }

                pending = nodeLine;
                continue;
            }

            var continuation = line.Trim();
            if (pending is { } open && continuation.Length > 0)
            {
                pending = (open.Indent, open.Text + " " + continuation);
            }
        }

        return AppendPending() ? nodes : null;
    }

    private static (int Indent, string Text)? NodeLine(string line)
    {
        var indent = 0;
        var i = 0;
        for (; i < line.Length && line[i] is ' ' or '\t'; i++)
        {
            indent += line[i] == '\t' ? 4 : 1;
        }

        if (!line.AsSpan(i).StartsWith("->", StringComparison.Ordinal))
        {
            return null;
        }

        var text = line[(i + 2)..].Trim();
        return text.Length == 0 ? null : (indent, text);
    }

    private static QueryPlanNode MakeNode(string rawText, IReadOnlyList<QueryPlanNode> children)
    {
        var text = rawText.Trim();
        double? startup = null, total = null, cost = null;
        long? actualRows = null, loops = null, estimatedRows = null;
        var executed = true;

        if (ActualMetrics().Match(text) is { Success: true } actual)
        {
            startup = NonNegative(actual.Groups[1].Value);
            total = NonNegative(actual.Groups[2].Value);
            actualRows = Rounded(actual.Groups[3].Value);
            loops = Whole(actual.Groups[4].Value);
            text = Removing(actual, text);
        }
        else if (NeverExecuted().Match(text) is { Success: true } never)
        {
            executed = false;
            text = Removing(never, text);
        }

        if (CostMetrics().Match(text) is { Success: true } estimate)
        {
            cost = NonNegative(estimate.Groups[1].Value);
            estimatedRows = Rounded(estimate.Groups[2].Value);
            text = Removing(estimate, text);
        }

        var (operation, relation, properties) = AccessPresentation(text);
        if (!executed)
        {
            properties["Execution"] = CoreStrings.Get("Plan/NeverExecuted");
        }

        return new QueryPlanNode
        {
            Operation = operation,
            Relation = relation,
            EstimatedTotalCost = cost,
            EstimatedRows = estimatedRows,
            ActualStartupTime = startup,
            ActualTotalTime = total,
            ActualRows = actualRows,
            ActualLoops = loops,
            Properties = properties,
            Children = children,
        };
    }

    private static (string Operation, string? Relation, Dictionary<string, string> Properties) AccessPresentation(string text)
    {
        var properties = new Dictionary<string, string>(StringComparer.Ordinal);
        var on = text.IndexOf(" on ", StringComparison.OrdinalIgnoreCase);
        if (on < 0 || !IsAccessOperation(text[..on]))
        {
            return (text, null, properties);
        }

        var operation = text[..on].Trim();
        var remainder = text[(on + 4)..].Trim();
        if (LeadingIdentifier(remainder) is not { } relation)
        {
            return (text, null, properties);
        }

        properties["Details"] = text;
        var suffix = remainder[relation.Length..];
        var usingAt = suffix.IndexOf("using ", StringComparison.OrdinalIgnoreCase);
        if (usingAt >= 0 && LeadingIdentifier(suffix[(usingAt + 6)..]) is { } index)
        {
            properties["Index Name"] = index;
        }

        return (operation, relation, properties);
    }

    private static bool IsAccessOperation(string operation) =>
        operation.Contains("scan", StringComparison.OrdinalIgnoreCase)
        || operation.Contains("lookup", StringComparison.OrdinalIgnoreCase)
        || operation.Contains("search", StringComparison.OrdinalIgnoreCase);

    private static string? LeadingIdentifier(string text)
    {
        var trimmed = text.Trim();
        if (trimmed.Length == 0)
        {
            return null;
        }

        char? closing = trimmed[0] switch
        {
            '`' => '`',
            '<' => '>',
            _ => null,
        };

        if (closing is { } close && trimmed.IndexOf(close, 1) is var end and > 0)
        {
            return trimmed[..(end + 1)];
        }

        var length = 0;
        while (length < trimmed.Length && !char.IsWhiteSpace(trimmed[length]) && trimmed[length] != '(')
        {
            length++;
        }

        return length == 0 ? null : trimmed[..length];
    }

    private static string Removing(Match match, string text) => text.Remove(match.Index, match.Length).Trim();

    private static double? NonNegative(string text) =>
        double.TryParse(text, NumberStyles.Float, CultureInfo.InvariantCulture, out var value) && double.IsFinite(value) && value >= 0 ? value : null;

    private static long? Rounded(string text) =>
        NonNegative(text) is { } value && value < long.MaxValue ? (long)Math.Round(value, MidpointRounding.AwayFromZero) : null;

    private static long? Whole(string text) =>
        NonNegative(text) is { } value && Math.Round(value) == value && value < long.MaxValue ? (long)value : null;
}
