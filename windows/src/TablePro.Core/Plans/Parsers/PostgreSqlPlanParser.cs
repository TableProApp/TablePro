using System.Collections.Frozen;
using System.Text.Json;
using TablePro.Core.Localization;

namespace TablePro.Core.Plans.Parsers;

/// <summary>Reads PostgreSQL <c>EXPLAIN (FORMAT JSON)</c> and <c>EXPLAIN (ANALYZE, FORMAT JSON)</c>.</summary>
public static class PostgreSqlPlanParser
{
    private static readonly FrozenSet<string> KnownKeys = FrozenSet.Create(
        StringComparer.Ordinal,
        "Node Type", "Relation Name", "Schema", "Alias",
        "Startup Cost", "Total Cost", "Plan Rows", "Plan Width",
        "Actual Startup Time", "Actual Total Time", "Actual Rows", "Actual Loops",
        "Plans");

    public static QueryPlan? Parse(string rawText)
    {
        ArgumentNullException.ThrowIfNull(rawText);
        using var document = PlanJson.Parse(rawText.Trim());
        if (document?.RootElement is not { ValueKind: JsonValueKind.Array } array || array.GetArrayLength() == 0)
        {
            return null;
        }

        var first = array[0];
        if (first.Property("Plan") is not { ValueKind: JsonValueKind.Object } plan)
        {
            return null;
        }

        // PostgreSQL 9.3 and earlier report the run time as Total Runtime.
        var execution = first.Property("Execution Time").Number() ?? first.Property("Total Runtime").Number();
        return QueryPlanTreeBuilder.Finish(ParseNode(plan), rawText, PlanFormat.PostgresJson, first.Property("Planning Time").Number(), execution);
    }

    private static QueryPlanNode ParseNode(JsonElement node)
    {
        var children = new List<QueryPlanNode>();
        if (node.Property("Plans") is { ValueKind: JsonValueKind.Array } plans)
        {
            foreach (var child in plans.EnumerateArray())
            {
                if (child.ValueKind == JsonValueKind.Object)
                {
                    children.Add(ParseNode(child));
                }
            }
        }

        var properties = new Dictionary<string, string>(StringComparer.Ordinal);
        foreach (var property in node.EnumerateObject())
        {
            if (!KnownKeys.Contains(property.Name))
            {
                properties[property.Name] = property.Value.Spell();
            }
        }

        return new QueryPlanNode
        {
            Operation = node.Property("Node Type").String() ?? CoreStrings.Get("Plan/UnknownOperation"),
            Relation = node.Property("Relation Name").String(),
            Schema = node.Property("Schema").String(),
            Alias = node.Property("Alias").String(),
            EstimatedStartupCost = node.Property("Startup Cost").Number(),
            EstimatedTotalCost = node.Property("Total Cost").Number(),
            EstimatedRows = node.Property("Plan Rows").Integer(),
            EstimatedWidth = node.Property("Plan Width").Integer(),
            ActualStartupTime = node.Property("Actual Startup Time").Number(),
            ActualTotalTime = node.Property("Actual Total Time").Number(),

            // PostgreSQL 18 reports actual rows with two decimals; the model counts whole rows.
            ActualRows = node.Property("Actual Rows").Integer(),
            ActualLoops = node.Property("Actual Loops").Integer(),
            Properties = properties,
            Children = children,
        };
    }
}
