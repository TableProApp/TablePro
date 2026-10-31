using System.Globalization;
using System.Text;
using System.Text.Json;

namespace TablePro.Drivers.Trino;

/// <summary>How Trino types arrive in JSON and how a value is written back as a literal.</summary>
internal static class TrinoTypes
{
    // Presto also sends its sketch types as base64.
    private static readonly HashSet<string> BinaryTypes = new(StringComparer.Ordinal)
    {
        "varbinary", "hyperloglog", "p4hyperloglog", "khyperloglog", "kllsketch", "qdigest", "tdigest", "setdigest",
    };

    private static readonly HashSet<string> StructuredTypes = new(StringComparer.Ordinal) { "array", "map", "row" };

    private static readonly HashSet<string> NumericTypes = new(StringComparer.Ordinal)
    {
        "tinyint", "smallint", "integer", "int", "bigint", "real", "double", "decimal",
    };

    public static string BaseType(string type)
    {
        var trimmed = type.AsSpan().Trim();
        var paren = trimmed.IndexOf('(');
        if (paren >= 0)
        {
            trimmed = trimmed[..paren].TrimEnd();
        }

        return trimmed.ToString().ToLowerInvariant();
    }

    public static bool IsStructured(string type) => StructuredTypes.Contains(BaseType(type));

    public static bool IsNumeric(string type) => NumericTypes.Contains(BaseType(type));

    public static Type ClrType(string rawType) => BaseType(rawType) switch
    {
        "bigint" => typeof(long),
        "integer" or "int" => typeof(int),
        "smallint" => typeof(short),
        "tinyint" => typeof(sbyte),
        "double" => typeof(double),
        "real" => typeof(float),
        "boolean" => typeof(bool),
        "decimal" => typeof(decimal),
        var b when BinaryTypes.Contains(b) => typeof(byte[]),
        _ => typeof(string),
    };

    /// <summary>A decoder per column, chosen once so the per-cell work is a switch on the JSON kind.</summary>
    public static Func<JsonElement, object?> Decoder(string rawType)
    {
        var baseType = BaseType(rawType);
        return baseType switch
        {
            "bigint" => static e => e.ValueKind == JsonValueKind.Number && e.TryGetInt64(out var v) ? v : Text(e),
            "integer" or "int" => static e => e.ValueKind == JsonValueKind.Number && e.TryGetInt32(out var v) ? v : Text(e),
            "smallint" => static e => e.ValueKind == JsonValueKind.Number && e.TryGetInt16(out var v) ? v : Text(e),
            "tinyint" => static e => e.ValueKind == JsonValueKind.Number && e.TryGetSByte(out var v) ? v : Text(e),
            "double" => static e => Floating(e),
            "real" => static e => Floating(e) is double d ? (float)d : Text(e),

            // Decimals arrive as strings to keep their precision; one wider than decimal stays text.
            "decimal" => static e => decimal.TryParse(Text(e), NumberStyles.Float, CultureInfo.InvariantCulture, out var m) ? m : Text(e),
            "boolean" => static e => e.ValueKind switch
            {
                JsonValueKind.True => true,
                JsonValueKind.False => false,
                _ => Text(e),
            },
            _ when BinaryTypes.Contains(baseType) => static e => e.ValueKind == JsonValueKind.String && e.TryGetBytesFromBase64(out var bytes) ? bytes : Text(e),
            _ when StructuredTypes.Contains(baseType) => static e => Structured(e),
            _ => static e => Text(e),
        };
    }

    public static object? Decode(JsonElement element, Func<JsonElement, object?> decoder) =>
        element.ValueKind is JsonValueKind.Null or JsonValueKind.Undefined ? null : decoder(element);

    private static string Text(JsonElement element) =>
        element.ValueKind == JsonValueKind.String ? element.GetString() ?? string.Empty : element.GetRawText();

    private static object Floating(JsonElement element)
    {
        if (element.ValueKind == JsonValueKind.Number && element.TryGetDouble(out var d))
        {
            return d;
        }

        // NaN and the infinities arrive as strings.
        return element.ValueKind == JsonValueKind.String && double.TryParse(element.GetString(), NumberStyles.Float, CultureInfo.InvariantCulture, out var parsed)
            ? parsed
            : Text(element);
    }

    // Presto 0.29x sends array, map and row values as their JSON text instead of as JSON.
    private static string Structured(JsonElement element) =>
        element.ValueKind == JsonValueKind.String ? element.GetString() ?? string.Empty : element.GetRawText();

    public static string QuoteIdentifier(string name) => string.Concat("\"", name.Replace("\"", "\"\"", StringComparison.Ordinal), "\"");

    /// <summary>Trino strings have no backslash escapes, so doubling the quote is the whole escape.</summary>
    public static string QuoteLiteral(string value) => string.Concat("'", value.Replace("'", "''", StringComparison.Ordinal), "'");

    /// <summary>
    /// Writes a value as a literal of the column's type. The REST protocol has no parameter binding (EXECUTE ... USING
    /// takes literals too), so a typed literal is how a value reaches a statement, and Trino refuses to compare a
    /// bigint with a varchar.
    /// </summary>
    public static string Literal(object? value, string? columnType)
    {
        var type = columnType ?? "varchar";
        return value switch
        {
            null or DBNull => "NULL",
            bool b => b ? "true" : "false",
            byte[] bytes => string.Concat("X'", Convert.ToHexString(bytes), "'"),
            string s => TextLiteral(s, type),
            DateTime dt => TextLiteral(dt.ToString(dt.TimeOfDay == TimeSpan.Zero && BaseType(type) == "date" ? "yyyy-MM-dd" : "yyyy-MM-dd HH:mm:ss.FFFFFFF", CultureInfo.InvariantCulture), type),
            DateTimeOffset dto => TextLiteral(dto.ToString("yyyy-MM-dd HH:mm:ss.FFFFFFF zzz", CultureInfo.InvariantCulture), type),
            DateOnly d => TextLiteral(d.ToString("yyyy-MM-dd", CultureInfo.InvariantCulture), type),
            TimeOnly t => TextLiteral(t.ToString("HH:mm:ss.FFFFFFF", CultureInfo.InvariantCulture), type),
            Guid g => TextLiteral(g.ToString(), type),
            float f => TextLiteral(f.ToString("R", CultureInfo.InvariantCulture), type),
            double d => TextLiteral(d.ToString("R", CultureInfo.InvariantCulture), type),
            IFormattable number when value.GetType().IsPrimitive || value is decimal => TextLiteral(number.ToString(null, CultureInfo.InvariantCulture), type),
            _ => TextLiteral(Convert.ToString(value, CultureInfo.InvariantCulture) ?? string.Empty, type),
        };
    }

    public static string TextLiteral(string text, string type)
    {
        var baseType = BaseType(type);
        switch (baseType)
        {
            case "boolean":
                return text.Trim().ToUpperInvariant() switch
                {
                    "TRUE" or "T" or "1" or "YES" => "true",
                    "FALSE" or "F" or "0" or "NO" => "false",
                    _ => QuoteLiteral(text),
                };
            case var _ when NumericTypes.Contains(baseType):
                return IsNumber(text) ? text.Trim() : QuoteLiteral(text);
            case "date":
                return "DATE " + QuoteLiteral(text);
            case "json":
                return "JSON " + QuoteLiteral(text);
            case "uuid":
                return "UUID " + QuoteLiteral(text);
            case "ipaddress":
                return string.Concat("CAST(", QuoteLiteral(text), " AS ipaddress)");
            case "varbinary":
                return string.Concat("from_hex(", QuoteLiteral(text.StartsWith("0x", StringComparison.OrdinalIgnoreCase) ? text[2..] : text), ")");
            case "array" or "map" or "row":
                return string.Concat("CAST(json_parse(", QuoteLiteral(text), ") AS ", type, ")");
        }

        if (baseType.StartsWith("timestamp", StringComparison.Ordinal))
        {
            return "TIMESTAMP " + QuoteLiteral(text);
        }

        return baseType.StartsWith("time", StringComparison.Ordinal) ? "TIME " + QuoteLiteral(text) : QuoteLiteral(text);
    }

    /// <summary>A plain decimal or exponent number, so the text can be written unquoted without changing the statement.</summary>
    public static bool IsNumber(string text)
    {
        var span = text.AsSpan().Trim();
        if (span.IsEmpty)
        {
            return false;
        }

        var i = span[0] is '+' or '-' ? 1 : 0;
        var digits = false;
        var dot = false;
        for (; i < span.Length; i++)
        {
            var c = span[i];
            if (char.IsAsciiDigit(c))
            {
                digits = true;
            }
            else if (c == '.' && !dot)
            {
                dot = true;
            }
            else if (c is 'e' or 'E' && digits)
            {
                var rest = span[(i + 1)..];
                if (rest.Length > 0 && rest[0] is '+' or '-')
                {
                    rest = rest[1..];
                }

                return rest.Length > 0 && !rest.ContainsAnyExceptInRange('0', '9');
            }
            else
            {
                return false;
            }
        }

        return digits;
    }

    public static string Describe(TrinoErrorInfo error)
    {
        var sb = new StringBuilder(error.Message);
        if (error.ErrorLocation is { LineNumber: > 0 } location)
        {
            sb.Append(CultureInfo.InvariantCulture, $" (line {location.LineNumber}, column {location.ColumnNumber})");
        }

        return sb.ToString();
    }
}
