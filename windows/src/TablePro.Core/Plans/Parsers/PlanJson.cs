using System.Globalization;
using System.Text;
using System.Text.Json;

namespace TablePro.Core.Plans.Parsers;

/// <summary>Reading plan JSON without reflection: a <see cref="JsonDocument"/> over a <see cref="Utf8JsonReader"/>.</summary>
internal static class PlanJson
{
    // A plan nests two levels per step ("Plans": [ { ... } ]), so the reader's default of 64 stops at 32 steps.
    private static readonly JsonDocumentOptions Options = new() { MaxDepth = 4096 };

    /// <summary>The whole text as one JSON value, or null when it is not JSON.</summary>
    public static JsonDocument? Parse(string text)
    {
        try
        {
            return JsonDocument.Parse(text, Options);
        }
        catch (JsonException)
        {
            return null;
        }
    }

    /// <summary>
    /// The first JSON value in the text, ignoring anything around it: DuckDB returns its plan beside a key column, so
    /// the flattened text leads with that key.
    /// </summary>
    public static JsonDocument? ParseFirstValue(string text)
    {
        var start = text.AsSpan().IndexOfAny('[', '{');
        if (start < 0)
        {
            return null;
        }

        var bytes = Encoding.UTF8.GetBytes(text.Substring(start));
        var reader = new Utf8JsonReader(bytes, new JsonReaderOptions { MaxDepth = Options.MaxDepth });
        try
        {
            return JsonDocument.TryParseValue(ref reader, out var document) ? document : null;
        }
        catch (JsonException)
        {
            return null;
        }
    }

    public static JsonElement? Property(this JsonElement element, string name) =>
        element.ValueKind == JsonValueKind.Object && element.TryGetProperty(name, out var value) ? value : null;

    /// <summary>A number, or a string holding one: MySQL writes its costs as strings.</summary>
    public static double? Number(this JsonElement? element)
    {
        if (element is not { } value)
        {
            return null;
        }

        return value.ValueKind switch
        {
            JsonValueKind.Number when value.TryGetDouble(out var d) => d,
            JsonValueKind.String when double.TryParse(value.GetString(), NumberStyles.Float, CultureInfo.InvariantCulture, out var d) => d,
            _ => null,
        };
    }

    public static long? Integer(this JsonElement? element) => element.Number() is { } d ? QueryPlanTreeBuilder.BoundedInteger(d) : null;

    public static string? String(this JsonElement? element) =>
        element is { ValueKind: JsonValueKind.String } value ? value.GetString() : null;

    /// <summary>
    /// Any value as the text a node property shows: a list of names joined by commas, a number in its shortest
    /// invariant spelling (so 0.00 reads as 0 and the zero filter recognises it), and an object as compact JSON.
    /// </summary>
    public static string Spell(this JsonElement value)
    {
        switch (value.ValueKind)
        {
            case JsonValueKind.String:
                return value.GetString() ?? string.Empty;
            case JsonValueKind.Number:
                return value.TryGetDouble(out var d) ? d.ToString(CultureInfo.InvariantCulture) : value.GetRawText();
            case JsonValueKind.True:
                return "true";
            case JsonValueKind.False:
                return "false";
            case JsonValueKind.Null:
                return "null";
            case JsonValueKind.Array when value.EnumerateArray().All(IsScalar):
                return string.Join(", ", value.EnumerateArray().Select(Spell));
            default:
                return value.GetRawText();
        }
    }

    private static bool IsScalar(JsonElement value) => value.ValueKind is not (JsonValueKind.Object or JsonValueKind.Array);
}
