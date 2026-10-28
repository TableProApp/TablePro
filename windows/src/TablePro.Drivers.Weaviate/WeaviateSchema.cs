using System.Globalization;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;
using System.Text.RegularExpressions;
using TablePro.Core.Browse;
using TablePro.Core.Schema;
using TablePro.Drivers.Http;

namespace TablePro.Drivers.Weaviate;

/// <summary>The value field a filter compares with. Weaviate has no array value field, so an array uses its element's.</summary>
internal enum WvKind
{
    Text,
    Uuid,
    Int,
    Number,
    Boolean,
    Date,
}

/// <summary>How a property is selected in GraphQL: a structured type needs a sub-selection or the query fails.</summary>
internal enum WvShape
{
    Scalar,
    GeoCoordinates,
    PhoneNumber,
    Object,
    CrossReference,
}

internal sealed record WvProperty(string Name, IReadOnlyList<string> DataTypes, IReadOnlyList<WvProperty> Nested)
{
    public string DataType => DataTypes.Count > 0 ? DataTypes[0] : "text";

    public bool IsArray => DataType.EndsWith("[]", StringComparison.Ordinal);

    public string Element => DataType.TrimEnd('[', ']');

    public WvKind Kind => KindOf(DataType);

    public WvShape Shape => Element switch
    {
        "text" or "string" or "int" or "number" or "boolean" or "bool" or "date" or "uuid" or "blob" => WvShape.Scalar,
        "geoCoordinates" => WvShape.GeoCoordinates,
        "phoneNumber" => WvShape.PhoneNumber,
        "object" => WvShape.Object,

        // A data type naming a class is a cross reference; classes start with a capital letter.
        _ when Element.Length > 0 && char.IsUpper(Element[0]) => WvShape.CrossReference,
        _ => WvShape.Scalar,
    };

    public Type ClrType => IsArray ? typeof(string) : Element switch
    {
        "int" => typeof(long),
        "number" => typeof(double),
        "boolean" or "bool" => typeof(bool),
        _ => typeof(string),
    };

    public static WvKind KindOf(string dataType) => dataType.Trim().TrimEnd('[', ']').ToLowerInvariant() switch
    {
        "int" => WvKind.Int,
        "number" => WvKind.Number,
        "boolean" or "bool" => WvKind.Boolean,
        "date" => WvKind.Date,
        "uuid" => WvKind.Uuid,
        _ => WvKind.Text,
    };

    public static WvProperty Parse(JsonElement json)
    {
        var types = json.TryGetProperty("dataType", out var dt) && dt.ValueKind == JsonValueKind.Array
            ? dt.EnumerateArray().Select(t => t.GetString() ?? "text").ToArray()
            : [];
        var nested = json.TryGetProperty("nestedProperties", out var np) && np.ValueKind == JsonValueKind.Array
            ? np.EnumerateArray().Select(Parse).ToArray()
            : [];
        return new WvProperty(json.GetProperty("name").GetString() ?? string.Empty, types, nested);
    }
}

internal sealed partial record WvClass(string Name, IReadOnlyList<WvProperty> Properties, bool MultiTenant)
{
    /// <summary>The grid's key column. Weaviate reserves <c>id</c> as a property name, so it cannot collide.</summary>
    public const string IdColumn = "id";

    public IReadOnlyDictionary<string, WvProperty> ByName { get; } =
        Properties.GroupBy(p => p.Name, StringComparer.Ordinal).ToDictionary(g => g.Key, g => g.First(), StringComparer.Ordinal);

    public static WvClass Parse(JsonElement json)
    {
        var properties = json.TryGetProperty("properties", out var list) && list.ValueKind == JsonValueKind.Array
            ? list.EnumerateArray().Select(WvProperty.Parse).ToArray()
            : [];
        var multiTenant = json.TryGetProperty("multiTenancyConfig", out var mt) && mt.TryGetProperty("enabled", out var enabled) && enabled.ValueKind == JsonValueKind.True;
        return new WvClass(json.GetProperty("class").GetString() ?? string.Empty, properties, multiTenant);
    }

    /// <summary>
    /// A class or property name goes into GraphQL text, so it must be a GraphQL name, which is all Weaviate allows
    /// anyway. Anything else is refused rather than spliced.
    /// </summary>
    public static string CheckedName(string name) =>
        GraphQlName().IsMatch(name) ? name : throw new ArgumentException($"{name} is not a valid Weaviate name.");

    public static bool IsName(string name) => GraphQlName().IsMatch(name);

    [GeneratedRegex("^[_A-Za-z][_0-9A-Za-z]*$")]
    private static partial Regex GraphQlName();
}

/// <summary>Builds GraphQL Get and Aggregate queries and their <c>where</c> filters.</summary>
internal static class WvGraphQl
{
    public static string Get(WvClass cls, BrowseRequest request, string? tenant)
    {
        var args = new List<string>
        {
            string.Create(CultureInfo.InvariantCulture, $"limit: {Math.Max(request.Limit, 0)}"),
            string.Create(CultureInfo.InvariantCulture, $"offset: {Math.Max(request.Offset, 0)}"),
        };
        if (Where(request.Filter, cls) is { } where)
        {
            args.Add("where: " + where);
        }

        var sorts = request.Sort
            .Where(s => s.Column == WvClass.IdColumn || (cls.ByName.ContainsKey(s.Column) && WvClass.IsName(s.Column)))
            .Select(s => $"{{ path: [{Quote(s.Column)}] order: {(s.Descending ? "desc" : "asc")} }}")
            .ToArray();
        if (sorts.Length > 0)
        {
            args.Add($"sort: [{string.Join(' ', sorts)}]");
        }

        if (tenant is not null)
        {
            args.Add("tenant: " + Quote(tenant));
        }

        var fields = string.Join(' ', cls.Properties.Where(p => WvClass.IsName(p.Name)).Select(Selection).OfType<string>());
        return $"{{ Get {{ {WvClass.CheckedName(cls.Name)}({string.Join(", ", args)}) {{ {fields} _additional {{ id }} }} }} }}";
    }

    public static string Count(WvClass cls, BrowseFilter filter, string? tenant)
    {
        var args = new List<string>();
        if (Where(filter, cls) is { } where)
        {
            args.Add("where: " + where);
        }

        if (tenant is not null)
        {
            args.Add("tenant: " + Quote(tenant));
        }

        var arguments = args.Count == 0 ? string.Empty : $"({string.Join(", ", args)})";
        return $"{{ Aggregate {{ {WvClass.CheckedName(cls.Name)}{arguments} {{ meta {{ count }} }} }} }}";
    }

    /// <summary>A structured property needs its own sub-selection; an object with nothing declared inside is left out.</summary>
    private static string? Selection(WvProperty property) => property.Shape switch
    {
        WvShape.Scalar => property.Name,
        WvShape.GeoCoordinates => $"{property.Name} {{ latitude longitude }}",
        WvShape.PhoneNumber => $"{property.Name} {{ input internationalFormatted nationalFormatted countryCode national valid defaultCountry }}",
        WvShape.Object => property.Nested.Where(n => WvClass.IsName(n.Name)).Select(Selection).OfType<string>().ToArray() is { Length: > 0 } nested
            ? $"{property.Name} {{ {string.Join(' ', nested)} }}"
            : null,
        WvShape.CrossReference => $"{property.Name} {{ {string.Join(' ', property.DataTypes.Where(WvClass.IsName).Select(t => $"... on {t} {{ _additional {{ id }} }}"))} }}",
        _ => property.Name,
    };

    public static string? Where(BrowseFilter filter, WvClass cls)
    {
        var operands = new List<string>();
        foreach (var rule in filter.Rules)
        {
            if (rule.Enabled && Operand(rule, cls) is { } operand)
            {
                operands.Add(operand);
            }
        }

        // The raw filter is a where object the user wrote in Weaviate's own syntax.
        if (!string.IsNullOrWhiteSpace(filter.RawWhere))
        {
            var raw = filter.RawWhere.Trim();
            operands.Add(raw.StartsWith('{') ? raw : throw new ArgumentException("A raw Weaviate filter is a where object, such as { path: [\"title\"] operator: Like valueText: \"*a*\" }."));
        }

        return operands.Count switch
        {
            0 => null,
            1 => operands[0],
            _ => $"{{ operator: {(filter.MatchAll ? "And" : "Or")} operands: [{string.Join(' ', operands)}] }}",
        };
    }

    public static string? Operand(FilterRule rule, WvClass cls)
    {
        var value = rule.Value ?? string.Empty;
        if (rule.Column is null)
        {
            if (value.Length == 0)
            {
                return null;
            }

            var text = cls.Properties.Where(p => p.Kind == WvKind.Text && p.Shape == WvShape.Scalar && WvClass.IsName(p.Name))
                .Select(p => Like(p.Name, "*" + value + "*")).ToArray();
            return text.Length switch
            {
                0 => null,
                1 => text[0],
                _ => $"{{ operator: Or operands: [{string.Join(' ', text)}] }}",
            };
        }

        var column = rule.Column;
        var kind = column == WvClass.IdColumn ? WvKind.Text : cls.ByName.TryGetValue(column, out var property) ? property.Kind : WvKind.Text;
        var ordered = kind is WvKind.Int or WvKind.Number or WvKind.Date;
        return rule.Operator switch
        {
            FilterOperator.Equals => Compare("Equal", column, value, kind),
            FilterOperator.NotEquals => Compare("NotEqual", column, value, kind),
            FilterOperator.GreaterThan => ordered ? Compare("GreaterThan", column, value, kind) : throw Unordered(column, ">"),
            FilterOperator.GreaterOrEqual => ordered ? Compare("GreaterThanEqual", column, value, kind) : throw Unordered(column, ">="),
            FilterOperator.LessThan => ordered ? Compare("LessThan", column, value, kind) : throw Unordered(column, "<"),
            FilterOperator.LessOrEqual => ordered ? Compare("LessThanEqual", column, value, kind) : throw Unordered(column, "<="),
            FilterOperator.Between => ordered ? Between(rule, column, kind) : throw Unordered(column, "BETWEEN"),
            FilterOperator.Contains => TextOnly(kind, column, rule.Operator, Like(column, "*" + value + "*")),
            FilterOperator.NotContains => TextOnly(kind, column, rule.Operator, $"{{ operator: Not operands: [{Like(column, "*" + value + "*")}] }}"),
            FilterOperator.StartsWith => TextOnly(kind, column, rule.Operator, Like(column, value + "*")),
            FilterOperator.EndsWith => TextOnly(kind, column, rule.Operator, Like(column, "*" + value)),
            FilterOperator.In => List("ContainsAny", column, value, kind),
            FilterOperator.NotIn => List("ContainsNone", column, value, kind),

            // Null filters need indexNullState on the class; the server says so when it is off.
            FilterOperator.IsNull => $"{{ path: [{Quote(column)}] operator: IsNull valueBoolean: true }}",
            FilterOperator.IsNotNull => $"{{ path: [{Quote(column)}] operator: IsNull valueBoolean: false }}",

            // Weaviate counts length with len(prop), which needs indexPropertyLength; there is no length of an id.
            FilterOperator.IsEmpty => column != WvClass.IdColumn && kind == WvKind.Text ? $"{{ path: [{Quote($"len({column})")}] operator: Equal valueInt: 0 }}" : throw TextNeeded(column, rule.Operator),
            FilterOperator.IsNotEmpty => column != WvClass.IdColumn && kind == WvKind.Text ? $"{{ path: [{Quote($"len({column})")}] operator: GreaterThan valueInt: 0 }}" : throw TextNeeded(column, rule.Operator),
            _ => throw new NotSupportedException($"Weaviate cannot filter with {rule.Operator.DisplayName()}."),
        };
    }

    private static string Compare(string op, string column, string value, WvKind kind) =>
        $"{{ path: [{Quote(column)}] operator: {op} {ValueField(kind)}: {Literal(value, column, kind)} }}";

    private static string Like(string column, string pattern) => $"{{ path: [{Quote(column)}] operator: Like valueText: {Quote(pattern)} }}";

    private static string TextOnly(WvKind kind, string column, FilterOperator op, string operand) =>
        kind == WvKind.Text ? operand : throw TextNeeded(column, op);

    private static string List(string op, string column, string csv, WvKind kind)
    {
        var items = csv.Split(',', StringSplitOptions.TrimEntries | StringSplitOptions.RemoveEmptyEntries);
        if (items.Length == 0)
        {
            throw new ArgumentException($"IN on {column} needs at least one value.");
        }

        return $"{{ path: [{Quote(column)}] operator: {op} {ValueField(kind)}: [{string.Join(", ", items.Select(i => Literal(i, column, kind)))}] }}";
    }

    private static string Between(FilterRule rule, string column, WvKind kind)
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
                throw new ArgumentException($"BETWEEN on {column} needs an upper bound.");
            }

            (low, high) = (value[..comma], value[(comma + 1)..]);
        }

        return $"{{ operator: And operands: [{Compare("GreaterThanEqual", column, low, kind)} {Compare("LessThanEqual", column, high, kind)}] }}";
    }

    private static string ValueField(WvKind kind) => kind switch
    {
        WvKind.Int => "valueInt",
        WvKind.Number => "valueNumber",
        WvKind.Boolean => "valueBoolean",
        WvKind.Date => "valueDate",
        _ => "valueText",
    };

    /// <summary>A value checked against its kind and written as a GraphQL literal; text is always quoted and escaped.</summary>
    public static string Literal(string value, string column, WvKind kind)
    {
        var trimmed = value.Trim();
        return kind switch
        {
            WvKind.Int => long.TryParse(trimmed, NumberStyles.Integer, CultureInfo.InvariantCulture, out var i)
                ? i.ToString(CultureInfo.InvariantCulture)
                : throw new ArgumentException($"{column} is a numeric property, and {value} is not a number."),
            WvKind.Number => double.TryParse(trimmed, NumberStyles.Float, CultureInfo.InvariantCulture, out var d)
                ? d.ToString("R", CultureInfo.InvariantCulture)
                : throw new ArgumentException($"{column} is a numeric property, and {value} is not a number."),
            WvKind.Boolean => trimmed.ToLowerInvariant() switch
            {
                "true" or "1" => "true",
                "false" or "0" => "false",
                _ => throw new ArgumentException($"{column} is a boolean property, so it matches only true or false, not {value}."),
            },

            // Weaviate parses valueDate with Go's RFC 3339 layout and refuses a bare date.
            WvKind.Date => DateTimeOffset.TryParseExact(trimmed, ["yyyy-MM-dd'T'HH:mm:ssK", "yyyy-MM-dd'T'HH:mm:ss.FFFFFFFFFK"], CultureInfo.InvariantCulture, DateTimeStyles.None, out _)
                ? Quote(trimmed)
                : throw new ArgumentException($"{column} is a date property, and {value} is not an RFC 3339 timestamp such as 2024-01-31T00:00:00Z."),
            _ => Quote(value),
        };
    }

    public static string Quote(string value)
    {
        var sb = new StringBuilder(value.Length + 2).Append('"');
        foreach (var c in value)
        {
            switch (c)
            {
                case '\\': sb.Append("\\\\"); break;
                case '"': sb.Append("\\\""); break;
                case '\n': sb.Append("\\n"); break;
                case '\r': sb.Append("\\r"); break;
                case '\t': sb.Append("\\t"); break;
                default:
                    if (c < ' ')
                    {
                        sb.Append(CultureInfo.InvariantCulture, $"\\u{(int)c:x4}");
                    }
                    else
                    {
                        sb.Append(c);
                    }

                    break;
            }
        }

        return sb.Append('"').ToString();
    }

    private static ArgumentException Unordered(string column, string op) => new($"Weaviate compares only numbers and dates with {op}, and {column} is neither.");

    private static ArgumentException TextNeeded(string column, FilterOperator op) => new($"Weaviate matches text with {op.DisplayName()}, and {column} is not a text property.");
}

/// <summary>Grid values into the property JSON a write sends.</summary>
internal static class WvValues
{
    public static JsonObject Properties(IReadOnlyDictionary<string, object?> values, WvClass cls, bool skipNulls)
    {
        var properties = new JsonObject();
        foreach (var (column, value) in values)
        {
            if (column == WvClass.IdColumn || column.StartsWith("_additional", StringComparison.Ordinal) || (skipNulls && value is null))
            {
                continue;
            }

            cls.ByName.TryGetValue(column, out var property);
            properties[column] = Value(value, property);
        }

        return properties;
    }

    /// <summary>
    /// Only a property the grid shows as JSON is parsed back as JSON; parsing every type would send a text cell holding
    /// braces as an object, which Weaviate refuses.
    /// </summary>
    public static JsonNode? Value(object? value, WvProperty? property)
    {
        if (value is not string text || property is null)
        {
            return value is string plain ? JsonValue.Create(plain) : JsonCells.ToNode(value);
        }

        var trimmed = text.Trim();
        if (!property.IsArray)
        {
            switch (property.Kind)
            {
                case WvKind.Boolean when bool.TryParse(trimmed, out var flag):
                    return flag;
                case WvKind.Int when long.TryParse(trimmed, NumberStyles.Integer, CultureInfo.InvariantCulture, out var integer):
                    return integer;
                case WvKind.Number when double.TryParse(trimmed, NumberStyles.Float, CultureInfo.InvariantCulture, out var real):
                    return real;
            }
        }

        if ((property.IsArray || property.Shape != WvShape.Scalar) && JsonCells.TryParseStructure(trimmed) is { } structure)
        {
            return structure;
        }

        return text;
    }
}

internal static class WvObjects
{
    /// <summary>Declares the id and every property as columns, in schema order.</summary>
    public static DocumentTable NewTable(WvClass? cls)
    {
        var table = new DocumentTable();
        table.Declare(WvClass.IdColumn, "uuid", typeof(string));
        if (cls is not null)
        {
            foreach (var property in cls.Properties)
            {
                table.Declare(property.Name, property.DataType, property.ClrType);
            }
        }

        return table;
    }

    /// <summary>One REST object: <c>{ id, class, properties: { ... } }</c>.</summary>
    public static void AddRest(DocumentTable table, JsonElement obj)
    {
        table.NewRow();
        if (obj.TryGetProperty("id", out var id))
        {
            table.Set(WvClass.IdColumn, id);
        }

        if (obj.TryGetProperty("properties", out var properties) && properties.ValueKind == JsonValueKind.Object)
        {
            table.SetTopLevel(properties);
        }
    }

    /// <summary>
    /// One GraphQL Get row. <c>_additional</c> carries the id and, for a vector search, the distance or score the user
    /// asked for, so its other fields become columns too.
    /// </summary>
    public static void AddGraphQl(DocumentTable table, JsonElement row)
    {
        table.NewRow();
        foreach (var property in row.EnumerateObject())
        {
            if (property.Name == "_additional" && property.Value.ValueKind == JsonValueKind.Object)
            {
                foreach (var additional in property.Value.EnumerateObject())
                {
                    table.Set(additional.Name == "id" ? WvClass.IdColumn : "_additional." + additional.Name, additional.Value);
                }

                continue;
            }

            table.Set(property.Name, property.Value);
        }
    }

    /// <summary>The rows of <c>data.Get.&lt;Class&gt;</c>, for every class the query asked for.</summary>
    public static IEnumerable<(string Class, JsonElement Row)> GetRows(JsonElement response)
    {
        if (response.TryGetProperty("data", out var data) && data.ValueKind == JsonValueKind.Object
            && data.TryGetProperty("Get", out var get) && get.ValueKind == JsonValueKind.Object)
        {
            foreach (var cls in get.EnumerateObject())
            {
                if (cls.Value.ValueKind != JsonValueKind.Array)
                {
                    continue;
                }

                foreach (var row in cls.Value.EnumerateArray())
                {
                    yield return (cls.Name, row);
                }
            }
        }
    }

    public static DatabaseObject ToObject(WvClass cls, long? count) =>
        new(new ObjectName(null, cls.Name), ObjectKind.Collection, count, cls.MultiTenant ? "multi-tenant" : null);
}
