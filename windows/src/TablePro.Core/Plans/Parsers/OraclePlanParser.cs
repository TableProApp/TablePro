using System.Text.Json;
using TablePro.Core.Localization;

namespace TablePro.Core.Plans.Parsers;

/// <summary>
/// Oracle plan rows from PLAN_TABLE, or from V$SQL_PLAN_STATISTICS_ALL for an actual plan, as a JSON array of objects
/// keyed by column name. ID and PARENT_ID make the tree.
/// </summary>
public static class OraclePlanParser
{
    private const int MaximumDepth = 256;

    private static readonly (string Key, string Column)[] PropertyColumns =
    [
        ("Access Predicates", "ACCESS_PREDICATES"),
        ("Filter Predicates", "FILTER_PREDICATES"),
        ("Bytes", "BYTES"),
        ("CPU Cost", "CPU_COST"),
        ("I/O Cost", "IO_COST"),
        ("Partition Start", "PARTITION_START"),
        ("Partition Stop", "PARTITION_STOP"),
        ("Query Block", "QBLOCK_NAME"),
        ("Buffer Gets", "LAST_CR_BUFFER_GETS"),
        ("Disk Reads", "LAST_DISK_READS"),
        ("Memory Used", "LAST_MEMORY_USED"),
        ("Temp Space", "LAST_TEMPSEG_SIZE"),
    ];

    public static QueryPlan? Parse(string rawText)
    {
        ArgumentNullException.ThrowIfNull(rawText);
        using var document = PlanJson.Parse(rawText.Trim());
        if (document?.RootElement is not { ValueKind: JsonValueKind.Array } rows)
        {
            return null;
        }

        var steps = new List<(long Id, long? Parent, JsonElement Row)>();
        foreach (var row in rows.EnumerateArray())
        {
            if (row.ValueKind == JsonValueKind.Object && row.Property("ID").Integer() is { } id)
            {
                steps.Add((id, row.Property("PARENT_ID").Integer(), row));
            }
        }

        if (steps.Count == 0)
        {
            return null;
        }

        steps.Sort((a, b) => a.Id.CompareTo(b.Id));
        var ids = steps.Select(s => s.Id).ToHashSet();
        var childrenOf = new Dictionary<long, List<JsonElement>>();
        var roots = new List<JsonElement>();
        foreach (var (id, parent, row) in steps)
        {
            if (parent is { } p && p != id && ids.Contains(p))
            {
                if (!childrenOf.TryGetValue(p, out var list))
                {
                    childrenOf[p] = list = [];
                }

                list.Add(row);
            }
            else
            {
                roots.Add(row);
            }
        }

        QueryPlanNode Build(JsonElement row, int depth)
        {
            var children = depth < MaximumDepth && childrenOf.TryGetValue(row.Property("ID").Integer() ?? -1, out var list)
                ? list.Select(c => Build(c, depth + 1)).ToList()
                : [];
            return MakeNode(row, children);
        }

        if (QueryPlanTreeBuilder.Root(roots.Select(r => Build(r, 0)).ToList()) is not { } root)
        {
            return null;
        }

        double? elapsed = null;
        foreach (var (_, _, row) in steps)
        {
            if (row.Property("LAST_ELAPSED_TIME").Number() is { } microseconds)
            {
                elapsed = Math.Max(elapsed ?? microseconds, microseconds);
            }
        }

        return QueryPlanTreeBuilder.Finish(root, rawText, PlanFormat.OraclePlanRows, executionTime: elapsed / 1_000);
    }

    private static QueryPlanNode MakeNode(JsonElement row, List<QueryPlanNode> children)
    {
        string? Text(string key)
        {
            if (row.Property(key) is not { } value || value.ValueKind == JsonValueKind.Null)
            {
                return null;
            }

            var text = value.Spell().Trim();
            return text.Length == 0 ? null : text;
        }

        var operation = string.Join(' ', new[] { Text("OPERATION"), Text("OPTIONS") }.Where(t => t is not null));
        var isIndex = Text("OBJECT_TYPE")?.StartsWith("INDEX", StringComparison.OrdinalIgnoreCase) == true;
        var properties = new Dictionary<string, string>(StringComparer.Ordinal);
        if (isIndex)
        {
            QueryPlanTreeBuilder.SetIfPresent(properties, "Index Name", Text("OBJECT_NAME"));
        }

        foreach (var (key, column) in PropertyColumns)
        {
            QueryPlanTreeBuilder.SetIfPresent(properties, key, Text(column));
        }

        // V$SQL_PLAN_STATISTICS_ALL totals rows and time over every start; the model holds per-start values.
        var starts = row.Property("LAST_STARTS").Integer();
        long? actualRows = null;
        double? actualTime = null;
        if (starts is > 0)
        {
            actualRows = row.Property("LAST_OUTPUT_ROWS").Number() is { } output ? QueryPlanTreeBuilder.BoundedInteger(output / starts.Value) : null;
            actualTime = row.Property("LAST_ELAPSED_TIME").Number() / 1_000 / starts.Value;
        }
        else if (starts == 0)
        {
            properties["Execution"] = CoreStrings.Get("Plan/NeverExecuted");
        }

        return new QueryPlanNode
        {
            Operation = operation.Length == 0 ? CoreStrings.Get("Plan/UnknownOperation") : operation,
            Relation = isIndex ? null : Text("OBJECT_NAME"),
            Schema = Text("OBJECT_OWNER"),
            Alias = Text("OBJECT_ALIAS"),
            EstimatedTotalCost = row.Property("COST").Number(),
            EstimatedRows = row.Property("CARDINALITY").Integer(),
            ActualTotalTime = actualTime,
            ActualRows = actualRows,
            ActualLoops = starts,
            ReportedTotalActualRows = row.Property("LAST_OUTPUT_ROWS").Integer(),
            Properties = properties,
            Children = children,
        };
    }
}
