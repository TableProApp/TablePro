using System.Text.Json;

namespace TablePro.Drivers.Elasticsearch;

/// <summary>One leaf of an index mapping, under its dotted path.</summary>
internal sealed record EsField(string Name, string Type, bool HasKeyword)
{
    private static readonly HashSet<string> TextTypes = ["text", "match_only_text", "search_as_you_type"];
    private static readonly HashSet<string> IntegerTypes = ["long", "integer", "short", "byte"];
    private static readonly HashSet<string> RealTypes = ["double", "float", "half_float", "scaled_float"];

    public bool IsText => TextTypes.Contains(Type);

    public bool IsNumeric => IntegerTypes.Contains(Type) || RealTypes.Contains(Type) || Type == "unsigned_long";

    /// <summary>Whole values are kept as JSON: an object, a nested array or a flattened map.</summary>
    public bool IsStructured => Type is "object" or "nested" or "flattened" or "join";

    public Type ClrType => Type switch
    {
        _ when IntegerTypes.Contains(Type) => typeof(long),
        _ when RealTypes.Contains(Type) => typeof(double),
        "unsigned_long" => typeof(decimal),
        "boolean" => typeof(bool),
        _ => typeof(string),
    };

    /// <summary>
    /// The field exact-value queries and sorts go to: a text field only through its keyword sub-field, since an analysed
    /// field has no single value to compare.
    /// </summary>
    public string? KeywordPath => IsText ? (HasKeyword ? Name + ".keyword" : null) : Name;
}

internal static class EsMapping
{
    public const string IdColumn = "_id";
    public const string IndexColumn = "_index";
    public const string ScoreColumn = "_score";

    /// <summary>
    /// Reads <c>GET /index/_mapping</c>. An alias or wildcard answers once per real index, so the first index to declare
    /// a field wins and the result does not depend on the order the server lists them in.
    /// </summary>
    public static IReadOnlyList<EsField> Parse(JsonElement response, string index)
    {
        var fields = new Dictionary<string, EsField>(StringComparer.Ordinal);
        if (response.ValueKind != JsonValueKind.Object)
        {
            return [];
        }

        var indices = response.TryGetProperty(index, out var exact)
            ? [exact]
            : response.EnumerateObject().OrderBy(p => p.Name, StringComparer.Ordinal).Select(p => p.Value).ToArray();

        foreach (var entry in indices)
        {
            if (entry.ValueKind == JsonValueKind.Object && entry.TryGetProperty("mappings", out var mappings) && mappings.ValueKind == JsonValueKind.Object
                && mappings.TryGetProperty("properties", out var properties) && properties.ValueKind == JsonValueKind.Object)
            {
                Collect(properties, string.Empty, fields);
            }
        }

        return [.. fields.Values.OrderBy(f => f.Name, StringComparer.OrdinalIgnoreCase)];
    }

    private static void Collect(JsonElement properties, string prefix, Dictionary<string, EsField> into)
    {
        foreach (var property in properties.EnumerateObject())
        {
            var path = prefix.Length == 0 ? property.Name : $"{prefix}.{property.Name}";
            var field = property.Value;
            var type = field.TryGetProperty("type", out var t) ? t.GetString() ?? "object" : "object";

            // A nested array is one value: its leaves would be lists, and writing one leaf would conflict with the array.
            if (type != "nested" && field.TryGetProperty("properties", out var children))
            {
                Collect(children, path, into);
                continue;
            }

            var hasKeyword = field.TryGetProperty("fields", out var subfields)
                && subfields.EnumerateObject().Any(s => s.Value.TryGetProperty("type", out var st) && st.GetString() == "keyword");
            into.TryAdd(path, new EsField(path, type, hasKeyword));
        }
    }
}
