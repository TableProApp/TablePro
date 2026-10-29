using System.Globalization;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;
using TablePro.Core.Browse;
using TablePro.Core.Localization;

namespace TablePro.Drivers.Elasticsearch;

/// <summary>Translates the filter strip and sort into Query DSL. Values travel as JSON values, never as query text.</summary>
internal static class EsQuery
{
    /// <summary>
    /// The bool query for a filter, or <c>match_all</c> when nothing filters. <paramref name="caseInsensitive"/> says
    /// whether the cluster understands <c>case_insensitive</c>, added in 7.10.
    /// </summary>
    public static JsonObject Build(BrowseFilter filter, IReadOnlyDictionary<string, EsField> fields, bool caseInsensitive = true)
    {
        var clauses = new List<JsonNode>();
        foreach (var rule in filter.Rules)
        {
            if (rule.Enabled && Clause(rule, fields, caseInsensitive) is { } clause)
            {
                clauses.Add(clause);
            }
        }

        if (!string.IsNullOrWhiteSpace(filter.RawWhere))
        {
            clauses.Add(Raw(filter.RawWhere));
        }

        if (clauses.Count == 0)
        {
            return new JsonObject { ["match_all"] = new JsonObject() };
        }

        if (clauses.Count == 1)
        {
            return (JsonObject)clauses[0];
        }

        return filter.MatchAll
            ? Bool("must", clauses)
            : new JsonObject { ["bool"] = new JsonObject { ["should"] = Array(clauses), ["minimum_should_match"] = 1 } };
    }

    /// <summary>
    /// The raw filter is Query DSL when it is a JSON object, otherwise Lucene query string syntax, which is what a
    /// search box over Elasticsearch takes.
    /// </summary>
    private static JsonObject Raw(string raw)
    {
        var trimmed = raw.Trim();
        if (trimmed.StartsWith('{'))
        {
            try
            {
                if (JsonNode.Parse(trimmed) is JsonObject query)
                {
                    return query;
                }
            }
            catch (JsonException)
            {
                // Not JSON after all; the query string parser reports what is wrong with it.
            }
        }

        return new JsonObject { ["query_string"] = new JsonObject { ["query"] = trimmed, ["lenient"] = true } };
    }

    public static JsonObject? Clause(FilterRule rule, IReadOnlyDictionary<string, EsField> fields, bool caseInsensitive = true)
    {
        var value = rule.Value ?? string.Empty;
        if (rule.Column is null)
        {
            // Every field, as the filter strip's search box means it: a substring anywhere.
            return value.Length == 0
                ? null
                : new JsonObject { ["query_string"] = new JsonObject { ["query"] = "*" + EscapeQueryString(value) + "*", ["lenient"] = true, ["analyze_wildcard"] = true } };
        }

        var column = rule.Column;
        fields.TryGetValue(column, out var field);
        var keyword = field is null ? column : field.KeywordPath ?? column;
        return rule.Operator switch
        {
            FilterOperator.Equals => EqualsClause(column, value, field),
            FilterOperator.NotEquals => Not(EqualsClause(column, value, field)),
            FilterOperator.GreaterThan => Range(column, "gt", value, field),
            FilterOperator.GreaterOrEqual => Range(column, "gte", value, field),
            FilterOperator.LessThan => Range(column, "lt", value, field),
            FilterOperator.LessOrEqual => Range(column, "lte", value, field),
            FilterOperator.Between => Between(column, rule, field),
            FilterOperator.Contains => ContainsClause(column, value, field, keyword, caseInsensitive),
            FilterOperator.NotContains => Not(ContainsClause(column, value, field, keyword, caseInsensitive)),
            FilterOperator.StartsWith => field is { IsText: true, HasKeyword: false }
                ? new JsonObject { ["match_phrase_prefix"] = new JsonObject { [column] = value } }
                : Options("prefix", keyword, value, caseInsensitive),
            FilterOperator.EndsWith => Options("wildcard", keyword, "*" + EscapeWildcard(value), caseInsensitive),
            FilterOperator.IsNull => Not(Exists(column)),
            FilterOperator.IsNotNull => Exists(column),

            // Empty means missing or the empty string, which is how a keyword field holds "nothing".
            FilterOperator.IsEmpty => Not(Present(column, keyword)),
            FilterOperator.IsNotEmpty => Present(column, keyword),
            FilterOperator.In => Terms(keyword, value, field),
            FilterOperator.NotIn => Not(Terms(keyword, value, field)),
            _ => throw new NotSupportedException(CoreStrings.Format("Driver/CannotFilterWith", "Elasticsearch", rule.Operator.DisplayName())),
        };
    }

    /// <summary>The sort clauses, leaving out what Elasticsearch cannot sort: <c>_id</c>, analysed text, nested arrays.</summary>
    public static JsonArray Sort(IReadOnlyList<SortColumn> sorts, IReadOnlyDictionary<string, EsField> fields)
    {
        var array = new JsonArray();
        foreach (var sort in sorts)
        {
            if (SortField(sort.Column, fields) is { } name)
            {
                array.Add((JsonNode)new JsonObject { [name] = new JsonObject { ["order"] = sort.Descending ? "desc" : "asc" } });
            }
        }

        return array;
    }

    public static string? SortField(string column, IReadOnlyDictionary<string, EsField> fields)
    {
        if (column is EsMapping.ScoreColumn or EsMapping.IndexColumn)
        {
            return column;
        }

        if (column == EsMapping.IdColumn || !fields.TryGetValue(column, out var field) || field.IsStructured)
        {
            return null;
        }

        return field.KeywordPath;
    }

    /// <summary>A grid value as the JSON value the field holds, so a number compares as a number.</summary>
    public static JsonNode? Typed(string value, EsField? field)
    {
        if (field is null)
        {
            return value;
        }

        if (field.IsNumeric)
        {
            if (long.TryParse(value, NumberStyles.Integer, CultureInfo.InvariantCulture, out var integer))
            {
                return integer;
            }

            if (double.TryParse(value, NumberStyles.Float, CultureInfo.InvariantCulture, out var real))
            {
                return real;
            }
        }

        if (field.Type == "boolean" && bool.TryParse(value, out var flag))
        {
            return flag;
        }

        return value;
    }

    private static JsonObject EqualsClause(string column, string value, EsField? field)
    {
        if (field is { IsText: true })
        {
            return field.HasKeyword
                ? new JsonObject { ["term"] = new JsonObject { [column + ".keyword"] = value } }
                : new JsonObject { ["match_phrase"] = new JsonObject { [column] = value } };
        }

        return new JsonObject { ["term"] = new JsonObject { [column] = Typed(value, field) } };
    }

    private static JsonObject ContainsClause(string column, string value, EsField? field, string keyword, bool caseInsensitive)
    {
        // An analysed field already ignores case and matches words, which is what contains means for prose.
        if (field is { IsText: true, HasKeyword: false })
        {
            return new JsonObject { ["match"] = new JsonObject { [column] = new JsonObject { ["query"] = value, ["operator"] = "and" } } };
        }

        return Options("wildcard", keyword, "*" + EscapeWildcard(value) + "*", caseInsensitive);
    }

    private static JsonObject Range(string column, string bound, string value, EsField? field) =>
        new() { ["range"] = new JsonObject { [column] = new JsonObject { [bound] = Typed(value, field) } } };

    private static JsonObject Between(string column, FilterRule rule, EsField? field)
    {
        var (low, high) = Bounds(rule);
        return new JsonObject { ["range"] = new JsonObject { [column] = new JsonObject { ["gte"] = Typed(low, field), ["lte"] = Typed(high, field) } } };
    }

    /// <summary>The upper bound travels in its own field; an older filter row joined both with a comma.</summary>
    internal static (string Low, string High) Bounds(FilterRule rule)
    {
        var value = rule.Value ?? string.Empty;
        if (rule.SecondValue is { } second)
        {
            return (value.Trim(), second.Trim());
        }

        var comma = value.IndexOf(',', StringComparison.Ordinal);
        if (comma < 0)
        {
            throw new ArgumentException(CoreStrings.Format("Driver/BetweenNeedsUpperBound", rule.Column));
        }

        return (value[..comma].Trim(), value[(comma + 1)..].Trim());
    }

    private static JsonObject Terms(string field, string csv, EsField? info)
    {
        var values = new JsonArray();
        foreach (var item in csv.Split(',', StringSplitOptions.TrimEntries | StringSplitOptions.RemoveEmptyEntries))
        {
            values.Add(info is { IsText: true } ? item : Typed(item, info));
        }

        return new JsonObject { ["terms"] = new JsonObject { [field] = values } };
    }

    private static JsonObject Exists(string column) => new() { ["exists"] = new JsonObject { ["field"] = column } };

    private static JsonObject Present(string column, string keyword) =>
        new()
        {
            ["bool"] = new JsonObject
            {
                ["must"] = new JsonArray(Exists(column)),
                ["must_not"] = new JsonArray(new JsonObject { ["term"] = new JsonObject { [keyword] = string.Empty } }),
            },
        };

    private static JsonObject Options(string kind, string field, string value, bool caseInsensitive)
    {
        var options = new JsonObject { ["value"] = value };
        if (caseInsensitive)
        {
            options["case_insensitive"] = true;
        }

        return new JsonObject { [kind] = new JsonObject { [field] = options } };
    }

    private static JsonObject Not(JsonObject clause) => Bool("must_not", [clause]);

    private static JsonObject Bool(string occur, IEnumerable<JsonNode> clauses) => new() { ["bool"] = new JsonObject { [occur] = Array(clauses) } };

    private static JsonArray Array(IEnumerable<JsonNode> clauses)
    {
        var array = new JsonArray();
        foreach (var clause in clauses)
        {
            array.Add(clause);
        }

        return array;
    }

    internal static string EscapeWildcard(string value) =>
        value.Replace("\\", "\\\\", StringComparison.Ordinal).Replace("*", "\\*", StringComparison.Ordinal).Replace("?", "\\?", StringComparison.Ordinal);

    /// <summary>Escapes every character the query string parser reserves, so typed text is matched literally.</summary>
    internal static string EscapeQueryString(string value)
    {
        var sb = new StringBuilder(value.Length + 8);
        foreach (var c in value)
        {
            if ("+-=&|><!(){}[]^\"~*?:\\/ ".Contains(c, StringComparison.Ordinal))
            {
                sb.Append('\\');
            }

            sb.Append(c);
        }

        return sb.ToString();
    }
}
