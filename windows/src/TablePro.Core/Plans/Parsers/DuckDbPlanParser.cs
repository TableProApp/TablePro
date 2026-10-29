using System.Text.Json;
using TablePro.Core.Localization;

namespace TablePro.Core.Plans.Parsers;

/// <summary>
/// DuckDB's JSON plans: the physical plan <c>EXPLAIN (FORMAT JSON)</c> returns as an array of operators, and the
/// profile <c>EXPLAIN (ANALYZE, FORMAT JSON)</c> returns as one object with measured operators below it. DuckDB
/// prices nothing, so an estimated plan carries cardinalities only.
/// </summary>
public static class DuckDbPlanParser
{
    private const int MaximumDepth = 1024;

    public static QueryPlan? Parse(string rawText)
    {
        ArgumentNullException.ThrowIfNull(rawText);
        using var document = PlanJson.ParseFirstValue(rawText);
        if (document is null)
        {
            return null;
        }

        var top = document.RootElement;
        List<QueryPlanNode> roots;
        double? execution = null;
        if (top.ValueKind == JsonValueKind.Array)
        {
            roots = Operators(top, 0);
        }
        else if (top.ValueKind == JsonValueKind.Object && top.Property("children") is { ValueKind: JsonValueKind.Array } children)
        {
            roots = Operators(children, 0);
            execution = top.Property("latency").Number() * 1_000;
        }
        else
        {
            return null;
        }

        var root = QueryPlanTreeBuilder.Root(roots);
        return root is null ? null : QueryPlanTreeBuilder.Finish(root, rawText, PlanFormat.DuckDbJson, executionTime: execution);
    }

    private static List<QueryPlanNode> Operators(JsonElement array, int depth)
    {
        var nodes = new List<QueryPlanNode>();
        if (depth >= MaximumDepth)
        {
            return nodes;
        }

        foreach (var element in array.EnumerateArray())
        {
            if (element.ValueKind != JsonValueKind.Object)
            {
                continue;
            }

            var children = element.Property("children") is { ValueKind: JsonValueKind.Array } nested ? Operators(nested, depth + 1) : [];
            var name = element.Property("operator_name").String() ?? element.Property("name").String() ?? CoreStrings.Get("Plan/UnknownOperation");

            // The profile wraps the query in an operator for the EXPLAIN itself, which did none of the work.
            if (name == "EXPLAIN_ANALYZE")
            {
                nodes.AddRange(children);
                continue;
            }

            nodes.Add(MakeNode(element, name.Trim(), children));
        }

        return nodes;
    }

    private static QueryPlanNode MakeNode(JsonElement element, string name, List<QueryPlanNode> children)
    {
        var properties = new Dictionary<string, string>(StringComparer.Ordinal);
        string? relation = null, schema = null;
        long? estimated = null;
        if (element.Property("extra_info") is { ValueKind: JsonValueKind.Object } extra)
        {
            foreach (var property in extra.EnumerateObject())
            {
                switch (property.Name)
                {
                    case "Estimated Cardinality":
                        estimated = ((JsonElement?)property.Value).Integer();
                        break;
                    case "Table" when property.Value.ValueKind == JsonValueKind.String:
                        // DuckDB qualifies the table as catalog.schema.table.
                        var parts = property.Value.GetString()!.Split('.');
                        relation = parts[^1];
                        schema = parts.Length > 1 ? parts[^2] : null;
                        properties["Table"] = property.Value.GetString()!;
                        break;
                    default:
                        properties[property.Name] = property.Value.Spell();
                        break;
                }
            }
        }

        // The profile times each operator on its own, in seconds; the model's time includes the children, in milliseconds.
        double? total = null;
        if (element.Property("operator_timing").Number() is { } own)
        {
            total = own * 1_000;
            foreach (var child in children)
            {
                total += child.ActualTotalTime ?? 0;
            }
        }

        if (element.Property("operator_rows_scanned").Integer() is { } scanned and > 0)
        {
            properties["Rows Scanned"] = scanned.ToString(System.Globalization.CultureInfo.InvariantCulture);
        }

        return new QueryPlanNode
        {
            Operation = name,
            Relation = relation,
            Schema = schema,
            EstimatedRows = estimated,
            ActualTotalTime = total,
            ActualRows = element.Property("operator_cardinality").Integer(),
            ActualLoops = total is null ? null : 1,
            Properties = properties,
            Children = children,
        };
    }
}
