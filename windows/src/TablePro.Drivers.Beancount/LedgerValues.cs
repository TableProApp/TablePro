using System.Globalization;
using System.Text;
using System.Text.Json;

namespace TablePro.Drivers.Beancount;

/// <summary>
/// Reads the loosely typed values the backends print. A JSON value becomes a string, a long, a decimal, a double, a
/// bool, a list, a <see cref="LedgerRow"/> or null, and the readers below accept whichever form a backend chose.
/// </summary>
internal static class LedgerValues
{
    public static object? FromJson(JsonElement element)
    {
        switch (element.ValueKind)
        {
            case JsonValueKind.Object:
                var row = new LedgerRow(StringComparer.Ordinal);
                foreach (var property in element.EnumerateObject())
                {
                    row[property.Name] = FromJson(property.Value);
                }

                return row;
            case JsonValueKind.Array:
                var list = new List<object?>(element.GetArrayLength());
                foreach (var item in element.EnumerateArray())
                {
                    list.Add(FromJson(item));
                }

                return list;
            case JsonValueKind.String:
                return element.GetString();
            case JsonValueKind.Number:
                if (element.TryGetInt64(out var integer))
                {
                    return integer;
                }

                return element.TryGetDecimal(out var number) ? number : element.GetDouble();
            case JsonValueKind.True:
                return true;
            case JsonValueKind.False:
                return false;
            default:
                return null;
        }
    }

    /// <summary>The rows of a JSON array of objects, skipping anything that is not an object.</summary>
    public static List<LedgerRow> Rows(object? value)
    {
        var rows = new List<LedgerRow>();
        if (value is List<object?> list)
        {
            foreach (var item in list)
            {
                if (item is LedgerRow row)
                {
                    rows.Add(row);
                }
            }
        }

        return rows;
    }

    public static object? Get(this LedgerRow row, string key) => row.TryGetValue(key, out var value) ? value : null;

    /// <summary>A string or a number as text; anything else is absent.</summary>
    public static string? Text(object? value) => value switch
    {
        string s => s,
        bool b => b ? "1" : "0",
        long l => l.ToString(CultureInfo.InvariantCulture),
        int i => i.ToString(CultureInfo.InvariantCulture),
        decimal d => d.ToString(CultureInfo.InvariantCulture),
        double d => NumberText(d),
        _ => null,
    };

    public static long? Integer(object? value) => value switch
    {
        long l => l,
        int i => i,
        bool b => b ? 1 : 0,
        decimal d => decimal.ToInt64(decimal.Truncate(d)),
        double d when double.IsFinite(d) => (long)d,
        string s when long.TryParse(s, NumberStyles.AllowLeadingSign, CultureInfo.InvariantCulture, out var parsed) => parsed,
        _ => null,
    };

    public static bool TryParseDecimal(string? text, out decimal value) =>
        decimal.TryParse(text, NumberStyles.Float | NumberStyles.AllowThousands, CultureInfo.InvariantCulture, out value);

    /// <summary>A decimal without trailing zeros, as the macOS app prints a computed difference.</summary>
    public static string NormalizedText(decimal value)
    {
        var normalized = value / 1.0000000000000000000000000000m;
        return normalized == 0 ? "0" : normalized.ToString(CultureInfo.InvariantCulture);
    }

    /// <summary>The shortest round-trip form, dropping a trailing <c>.0</c>.</summary>
    public static string NumberText(double value)
    {
        var text = value.ToString("R", CultureInfo.InvariantCulture);
        return text.EndsWith(".0", StringComparison.Ordinal) ? text[..^2] : text;
    }

    /// <summary>Compact JSON with sorted keys, for structured values no other rendering covers.</summary>
    public static string Json(object? value)
    {
        using var stream = new MemoryStream();
        using (var writer = new Utf8JsonWriter(stream))
        {
            WriteJson(writer, value);
        }

        return Encoding.UTF8.GetString(stream.ToArray());
    }

    private static void WriteJson(Utf8JsonWriter writer, object? value)
    {
        switch (value)
        {
            case null:
                writer.WriteNullValue();
                break;
            case string s:
                writer.WriteStringValue(s);
                break;
            case bool b:
                writer.WriteBooleanValue(b);
                break;
            case long l:
                writer.WriteNumberValue(l);
                break;
            case int i:
                writer.WriteNumberValue(i);
                break;
            case decimal d:
                writer.WriteNumberValue(d);
                break;
            case double d when double.IsFinite(d):
                writer.WriteNumberValue(d);
                break;
            case LedgerRow row:
                writer.WriteStartObject();
                var keys = new List<string>(row.Keys);
                keys.Sort(StringComparer.Ordinal);
                foreach (var key in keys)
                {
                    writer.WritePropertyName(key);
                    WriteJson(writer, row[key]);
                }

                writer.WriteEndObject();
                break;
            case List<object?> list:
                writer.WriteStartArray();
                foreach (var item in list)
                {
                    WriteJson(writer, item);
                }

                writer.WriteEndArray();
                break;
            default:
                writer.WriteStringValue(Convert.ToString(value, CultureInfo.InvariantCulture));
                break;
        }
    }
}
