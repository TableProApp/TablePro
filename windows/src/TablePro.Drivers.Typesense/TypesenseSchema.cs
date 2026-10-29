using System.Globalization;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;
using TablePro.Core.Browse;
using TablePro.Core.Localization;
using TablePro.Drivers.Http;
using TablePro.Drivers.Typesense.Localization;

namespace TablePro.Drivers.Typesense;

/// <summary>One field of a collection schema.</summary>
internal sealed record TsField(string Name, string Type, bool IsSortable, bool IsOptional, bool IsFacet)
{
    public bool IsArray => Type.EndsWith("[]", StringComparison.Ordinal);

    public bool IsNumeric => Type is "int32" or "int64" or "float" or "int32[]" or "int64[]" or "float[]";

    public bool IsBoolean => Type is "bool" or "bool[]";

    public bool IsObject => Type is "object" or "object[]";

    public Type ClrType => Type switch
    {
        "int32" or "int64" => typeof(long),
        "float" => typeof(double),
        "bool" => typeof(bool),
        _ => typeof(string),
    };
}

internal sealed record TsCollection(string Name, long Documents, IReadOnlyList<TsField> Fields)
{
    public const string IdColumn = "id";

    /// <summary><c>id</c> is never in the schema's fields but filters like a string, and Typesense will not sort on it.</summary>
    public static readonly TsField IdField = new(IdColumn, "string", false, false, false);

    /// <summary>
    /// The fields that become columns. The auto-schema wildcard <c>.*</c> is not one, and an object whose leaves are
    /// declared is shown through those leaves.
    /// </summary>
    public IReadOnlyList<TsField> Columns { get; } = [.. Fields
        .Where(f => f.Name != ".*" && f.Name != IdColumn)
        .Where(f => !f.IsObject || !Fields.Any(o => o.Name.StartsWith(f.Name + ".", StringComparison.Ordinal)))
        .OrderBy(f => f.Name, StringComparer.OrdinalIgnoreCase)];

    public IReadOnlyDictionary<string, TsField> ByName { get; } =
        Fields.Where(f => f.Name != ".*").Append(IdField).GroupBy(f => f.Name, StringComparer.Ordinal).ToDictionary(g => g.Key, g => g.Last(), StringComparer.Ordinal);

    public static TsCollection Parse(JsonElement json)
    {
        var name = json.GetProperty("name").GetString() ?? string.Empty;
        var documents = json.TryGetProperty("num_documents", out var n) && n.ValueKind == JsonValueKind.Number ? n.GetInt64() : 0;
        var fields = new List<TsField>();
        if (json.TryGetProperty("fields", out var list))
        {
            foreach (var field in list.EnumerateArray())
            {
                var fieldName = field.TryGetProperty("name", out var fn) ? fn.GetString() : null;
                var type = field.TryGetProperty("type", out var ft) ? ft.GetString() : null;
                if (fieldName is null || type is null)
                {
                    continue;
                }

                // Numbers sort by default; servers before 0.23 do not report the flag at all.
                var sortable = field.TryGetProperty("sort", out var sort) ? sort.ValueKind == JsonValueKind.True
                    : type is "int32" or "int64" or "float" or "bool";
                fields.Add(new TsField(fieldName, type, sortable, Flag(field, "optional"), Flag(field, "facet")));
            }
        }

        return new TsCollection(name, documents, fields);

        static bool Flag(JsonElement field, string name) => field.TryGetProperty(name, out var value) && value.ValueKind == JsonValueKind.True;
    }
}

/// <summary>Turns the filter strip into a <c>filter_by</c> expression and the sort into <c>sort_by</c>.</summary>
internal static class TsFilter
{
    /// <summary>"Only upto 3 sort fields can be specified in a single search query."</summary>
    public const int MaxSortFields = 3;

    public static string? FilterBy(BrowseFilter filter, IReadOnlyDictionary<string, TsField> fields)
    {
        var clauses = new List<string>();
        foreach (var rule in filter.Rules)
        {
            if (rule.Enabled && rule.Column is not null)
            {
                clauses.Add(Clause(rule, fields));
            }
        }

        // The raw filter is a filter_by expression the user wrote, so it goes over as written.
        if (!string.IsNullOrWhiteSpace(filter.RawWhere))
        {
            clauses.Add(filter.RawWhere.Trim());
        }

        return clauses.Count switch
        {
            0 => null,
            1 => clauses[0],
            _ => string.Join(filter.MatchAll ? " && " : " || ", clauses.Select(c => $"({c})")),
        };
    }

    /// <summary>The all-columns search box becomes the full-text query over every string field.</summary>
    public static (string Q, string? QueryBy) Query(BrowseFilter filter, TsCollection collection)
    {
        var search = filter.Rules.FirstOrDefault(r => r.Enabled && r.Column is null && !string.IsNullOrEmpty(r.Value));
        if (search is null)
        {
            return ("*", null);
        }

        var strings = collection.Columns.Where(f => f.Type is "string" or "string[]" or "string*").Select(f => f.Name).ToArray();
        return strings.Length == 0 ? ("*", null) : (search.Value!, string.Join(',', strings));
    }

    public static string Clause(FilterRule rule, IReadOnlyDictionary<string, TsField> fields)
    {
        var column = rule.Column!;
        fields.TryGetValue(column, out var field);
        var value = rule.Value ?? string.Empty;
        return rule.Operator switch
        {
            FilterOperator.Equals => $"{column}:={Literal(value, column, field)}",
            FilterOperator.NotEquals => $"{column}:!={Literal(value, column, field)}",
            FilterOperator.GreaterThan => $"{column}:>{Numeric(value, column, ">", field)}",
            FilterOperator.GreaterOrEqual => $"{column}:>={Numeric(value, column, ">=", field)}",
            FilterOperator.LessThan => $"{column}:<{Numeric(value, column, "<", field)}",
            FilterOperator.LessOrEqual => $"{column}:<={Numeric(value, column, "<=", field)}",
            FilterOperator.Between => Between(rule, column, field),
            FilterOperator.In => $"{column}:=[{List(value, column, field)}]",
            FilterOperator.NotIn => $"{column}:!=[{List(value, column, field)}]",

            // A plain field:value is Typesense's token match on a string field, the nearest it has to contains.
            FilterOperator.Contains => $"{column}:{Text(value, column)}",
            FilterOperator.NotContains => $"{column}:!{Text(value, column)}",
            FilterOperator.StartsWith => $"{column}:{Text(value, column)}*",
            _ => throw new NotSupportedException(CoreStrings.Format("Driver/CannotFilterWith", "Typesense", rule.Operator.DisplayName())),
        };
    }

    public static string? SortBy(IReadOnlyList<SortColumn> sorts, IReadOnlyDictionary<string, TsField> fields)
    {
        // Sorting a field the schema does not mark sortable fails the whole search, so such a column is left out.
        var parts = sorts
            .Where(s => fields.TryGetValue(s.Column, out var f) && f.IsSortable)
            .Take(MaxSortFields)
            .Select(s => $"{s.Column}:{(s.Descending ? "desc" : "asc")}")
            .ToArray();
        return parts.Length == 0 ? null : string.Join(',', parts);
    }

    /// <summary>
    /// A numeric or boolean field takes a bare literal, which must then prove it is one: unquoted text would be read
    /// as filter syntax. Anything else is a backticked string.
    /// </summary>
    public static string Literal(string value, string column, TsField? field)
    {
        if (field is { IsNumeric: true })
        {
            return double.TryParse(value, NumberStyles.Float, CultureInfo.InvariantCulture, out _)
                ? value.Trim()
                : throw new ArgumentException(CoreStrings.Format("Driver/NumericFieldNotNumber", column, value));
        }

        if (field is { IsBoolean: true })
        {
            var lowered = value.Trim().ToLowerInvariant();
            return lowered is "true" or "false" ? lowered : throw new ArgumentException(CoreStrings.Format("Driver/BooleanFieldNotBoolean", column, value));
        }

        return Text(value, column);
    }

    /// <summary>Backticks are Typesense's only quoting and have no escape, so a value holding one cannot be filtered on.</summary>
    public static string Text(string value, string column) =>
        value.Contains('`', StringComparison.Ordinal)
            ? throw new ArgumentException(TypesenseStrings.Format("Typesense/BacktickInFilter", column))
            : $"`{value}`";

    private static string Numeric(string value, string column, string op, TsField? field)
    {
        // A string field matches nothing under a comparison rather than failing, which would read as an empty table.
        if ((field is not null && !field.IsNumeric) || !double.TryParse(value, NumberStyles.Float, CultureInfo.InvariantCulture, out _))
        {
            throw new ArgumentException(TypesenseStrings.Format("Typesense/ComparesNumbersOnly", op, column));
        }

        return value.Trim();
    }

    private static string Between(FilterRule rule, string column, TsField? field)
    {
        var value = rule.Value ?? string.Empty;
        string low, high;
        if (rule.SecondValue is { Length: > 0 } second)
        {
            (low, high) = (value, second);
        }
        else
        {
            var comma = value.IndexOf(',', StringComparison.Ordinal);
            if (comma < 0)
            {
                throw new ArgumentException(CoreStrings.Format("Driver/BetweenNeedsUpperBound", column));
            }

            (low, high) = (value[..comma], value[(comma + 1)..]);
        }

        // A Typesense range is inclusive at both ends, which is what BETWEEN means.
        return $"{column}:[{Numeric(low, column, "BETWEEN", field)}..{Numeric(high, column, "BETWEEN", field)}]";
    }

    private static string List(string csv, string column, TsField? field) =>
        string.Join(',', csv.Split(',', StringSplitOptions.TrimEntries | StringSplitOptions.RemoveEmptyEntries).Select(v => Literal(v, column, field)));
}

/// <summary>Grid values into the document JSON a write sends.</summary>
internal static class TsDocuments
{
    public static JsonObject Build(IReadOnlyDictionary<string, object?> values, IReadOnlyDictionary<string, TsField> fields, bool skipNulls)
    {
        var document = new JsonObject();
        foreach (var (column, value) in values)
        {
            if (skipNulls && value is null)
            {
                continue;
            }

            if (column == TsCollection.IdColumn && (value is null || (value is string s && s.Length == 0)))
            {
                continue;
            }

            fields.TryGetValue(column, out var field);
            var node = column == TsCollection.IdColumn ? JsonValue.Create(Convert.ToString(value, CultureInfo.InvariantCulture)) : Value(value, field);

            // A nested field's dotted name is a path into the document, which is how Typesense stores it.
            var parts = column.Split('.');
            var target = document;
            for (var i = 0; i < parts.Length - 1; i++)
            {
                if (target[parts[i]] is not JsonObject child)
                {
                    child = new JsonObject();
                    target[parts[i]] = child;
                }

                target = child;
            }

            target[parts[^1]] = node;
        }

        return document;
    }

    public static JsonNode? Value(object? value, TsField? field)
    {
        if (value is not string text || field is null)
        {
            return value is string plain ? JsonValue.Create(plain) : JsonCells.ToNode(value);
        }

        if (field.IsNumeric && !field.IsArray)
        {
            if (field.Type.StartsWith("int", StringComparison.Ordinal) && long.TryParse(text, NumberStyles.Integer, CultureInfo.InvariantCulture, out var integer))
            {
                return integer;
            }

            if (double.TryParse(text, NumberStyles.Float, CultureInfo.InvariantCulture, out var real))
            {
                return real;
            }
        }

        if (field.IsBoolean && !field.IsArray && bool.TryParse(text, out var flag))
        {
            return flag;
        }

        if ((field.IsArray || field.IsObject) && JsonCells.TryParseStructure(text) is { } structure)
        {
            return structure;
        }

        return text;
    }

    /// <summary>Typesense accepts a collection called a/b, so a name is always one escaped segment.</summary>
    public static string Segment(string value) => Uri.EscapeDataString(value);

    public static string Jsonl(IEnumerable<JsonObject> documents)
    {
        var sb = new StringBuilder();
        foreach (var document in documents)
        {
            sb.Append(JsonCells.ToJson(document)).Append('\n');
        }

        return sb.ToString();
    }
}
