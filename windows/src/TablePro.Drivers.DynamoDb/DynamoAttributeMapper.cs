using System.Buffers;
using System.Globalization;
using System.Text;
using System.Text.Encodings.Web;
using System.Text.Json;
using System.Text.RegularExpressions;
using Amazon.DynamoDBv2.Model;

namespace TablePro.Drivers.DynamoDb;

/// <summary>
/// Converts between DynamoDB attribute values and grid cells. String, Number, Binary, Boolean and Null stay native;
/// maps, lists and sets become plain JSON text, and the attribute's type decides how edited text is read back.
/// </summary>
public static partial class DynamoAttributeMapper
{
    public const string String = "S";
    public const string Number = "N";
    public const string Binary = "B";
    public const string Boolean = "BOOL";
    public const string Null = "NULL";
    public const string Map = "M";
    public const string List = "L";
    public const string StringSet = "SS";
    public const string NumberSet = "NS";
    public const string BinarySet = "BS";

    private static readonly JsonWriterOptions WriterOptions = new() { Encoder = JavaScriptEncoder.UnsafeRelaxedJsonEscaping };

    public static string TypeOf(AttributeValue value) => value switch
    {
        { S: not null } => String,
        { N: not null } => Number,
        { B: not null } => Binary,
        { BOOL: not null } => Boolean,
        { NULL: true } => Null,
        { M: not null } => Map,
        { L: not null } => List,
        { SS: not null } => StringSet,
        { NS: not null } => NumberSet,
        { BS: not null } => BinarySet,
        _ => Null,
    };

    public static bool IsComposite(string type) => type is Map or List or StringSet or NumberSet or BinarySet;

    public static object? ToCell(AttributeValue? value)
    {
        if (value is null)
        {
            return null;
        }

        return TypeOf(value) switch
        {
            String => value.S,
            Number => ParseNumber(value.N),
            Binary => value.B!.ToArray(),
            Boolean => value.BOOL!.Value,
            Null => null,
            _ => ToJson(value),
        };
    }

    /// <summary>A Number fits <see cref="decimal"/> unless it uses DynamoDB's full 38 digits or a large exponent; then it stays exact text.</summary>
    public static object ParseNumber(string text) =>
        decimal.TryParse(text, NumberStyles.Float, CultureInfo.InvariantCulture, out var number) ? number : text;

    public static bool IsNumber(string text) => NumberPattern().IsMatch(text);

    public static string ToJson(AttributeValue value)
    {
        var buffer = new ArrayBufferWriter<byte>(128);
        using (var writer = new Utf8JsonWriter(buffer, WriterOptions))
        {
            Write(writer, value);
        }

        return Encoding.UTF8.GetString(buffer.WrittenSpan);
    }

    /// <summary>
    /// The attribute for a cell. <paramref name="type"/> is the type the attribute held when it was read, which says
    /// whether JSON text is a map, a list or a set, and whether a typed number stays a Number.
    /// </summary>
    public static AttributeValue FromCell(object? value, string? type = null)
    {
        switch (value)
        {
            case null:
                return new AttributeValue { NULL = true };
            case AttributeValue attribute:
                return attribute;
            case bool b:
                return new AttributeValue { BOOL = b };
            case byte[] bytes:
                return new AttributeValue { B = new MemoryStream(bytes) };
            case string s:
                return FromText(s, type);
            case decimal or double or float or int or long or short or byte or sbyte or uint or ulong or ushort or System.Numerics.BigInteger:
                return new AttributeValue { N = FormatNumber(value) };
            case DateTime dt:
                return new AttributeValue { S = dt.ToString("O", CultureInfo.InvariantCulture) };
            case DateTimeOffset dto:
                return new AttributeValue { S = dto.ToString("O", CultureInfo.InvariantCulture) };
            default:
                return new AttributeValue { S = Convert.ToString(value, CultureInfo.InvariantCulture) ?? string.Empty };
        }
    }

    /// <summary>A key attribute, typed by the table's attribute definitions.</summary>
    public static AttributeValue KeyFromCell(object? value, string keyType)
    {
        if (value is null)
        {
            throw new InvalidOperationException("A key attribute cannot be empty.");
        }

        return keyType switch
        {
            Number => new AttributeValue { N = value is string s ? RequireNumber(s) : FormatNumber(value) },
            Binary => new AttributeValue { B = new MemoryStream(value as byte[] ?? DecodeBinary(Convert.ToString(value, CultureInfo.InvariantCulture) ?? string.Empty)) },
            _ => new AttributeValue { S = value as string ?? Convert.ToString(value, CultureInfo.InvariantCulture) ?? string.Empty },
        };
    }

    public static AttributeValue FromJson(JsonElement element, string? setType = null)
    {
        switch (element.ValueKind)
        {
            case JsonValueKind.Object:
                var map = new Dictionary<string, AttributeValue>(StringComparer.Ordinal);
                foreach (var property in element.EnumerateObject())
                {
                    map[property.Name] = FromJson(property.Value);
                }

                return new AttributeValue { M = map };
            case JsonValueKind.Array when setType == StringSet:
                return new AttributeValue { SS = [.. element.EnumerateArray().Select(e => e.ValueKind == JsonValueKind.String ? e.GetString()! : e.GetRawText())] };
            case JsonValueKind.Array when setType == NumberSet:
                return new AttributeValue { NS = [.. element.EnumerateArray().Select(e => RequireNumber(e.ValueKind == JsonValueKind.String ? e.GetString()! : e.GetRawText()))] };
            case JsonValueKind.Array when setType == BinarySet:
                return new AttributeValue { BS = [.. element.EnumerateArray().Select(e => new MemoryStream(DecodeBinary(e.GetString() ?? string.Empty)))] };
            case JsonValueKind.Array:
                return new AttributeValue { L = [.. element.EnumerateArray().Select(e => FromJson(e))] };
            case JsonValueKind.String:
                return new AttributeValue { S = element.GetString() };
            case JsonValueKind.Number:
                return new AttributeValue { N = element.GetRawText() };
            case JsonValueKind.True or JsonValueKind.False:
                return new AttributeValue { BOOL = element.GetBoolean() };
            default:
                return new AttributeValue { NULL = true };
        }
    }

    /// <summary>Binary typed into a cell: hex with a 0x prefix, as the grid shows it, else base64 as the AWS console shows it.</summary>
    public static byte[] DecodeBinary(string text)
    {
        var trimmed = text.Trim();
        if (trimmed.StartsWith("0x", StringComparison.OrdinalIgnoreCase))
        {
            return Convert.FromHexString(trimmed.AsSpan(2));
        }

        return Convert.FromBase64String(trimmed);
    }

    private static AttributeValue FromText(string text, string? type)
    {
        switch (type)
        {
            case Number when IsNumber(text.Trim()):
                return new AttributeValue { N = text.Trim() };
            case Binary:
                return new AttributeValue { B = new MemoryStream(DecodeBinary(text)) };
            case Boolean when bool.TryParse(text.Trim(), out var b):
                return new AttributeValue { BOOL = b };
            case Map or List or StringSet or NumberSet or BinarySet:
                using (var document = JsonDocument.Parse(text))
                {
                    var parsed = FromJson(document.RootElement, type);
                    return type == Map && parsed.M is null
                        ? throw new FormatException("A map attribute takes a JSON object.")
                        : parsed;
                }

            default:
                return new AttributeValue { S = text };
        }
    }

    private static string RequireNumber(string text) =>
        IsNumber(text.Trim()) ? text.Trim() : throw new FormatException($"\"{text}\" is not a number.");

    private static string FormatNumber(object value) => value switch
    {
        double d => d.ToString("R", CultureInfo.InvariantCulture),
        float f => f.ToString("R", CultureInfo.InvariantCulture),
        IFormattable formattable => formattable.ToString(null, CultureInfo.InvariantCulture),
        _ => Convert.ToString(value, CultureInfo.InvariantCulture) ?? "0",
    };

    private static void Write(Utf8JsonWriter writer, AttributeValue value)
    {
        switch (TypeOf(value))
        {
            case String:
                writer.WriteStringValue(value.S);
                break;
            case Number:
                WriteNumber(writer, value.N);
                break;
            case Binary:
                writer.WriteBase64StringValue(value.B!.ToArray());
                break;
            case Boolean:
                writer.WriteBooleanValue(value.BOOL!.Value);
                break;
            case Map:
                writer.WriteStartObject();
                foreach (var (name, item) in value.M.OrderBy(e => e.Key, StringComparer.Ordinal))
                {
                    writer.WritePropertyName(name);
                    Write(writer, item);
                }

                writer.WriteEndObject();
                break;
            case List:
                writer.WriteStartArray();
                foreach (var item in value.L)
                {
                    Write(writer, item);
                }

                writer.WriteEndArray();
                break;
            case StringSet:
                writer.WriteStartArray();
                foreach (var item in value.SS)
                {
                    writer.WriteStringValue(item);
                }

                writer.WriteEndArray();
                break;
            case NumberSet:
                writer.WriteStartArray();
                foreach (var item in value.NS)
                {
                    WriteNumber(writer, item);
                }

                writer.WriteEndArray();
                break;
            case BinarySet:
                writer.WriteStartArray();
                foreach (var item in value.BS)
                {
                    writer.WriteBase64StringValue(item.ToArray());
                }

                writer.WriteEndArray();
                break;
            default:
                writer.WriteNullValue();
                break;
        }
    }

    // DynamoDB numbers are JSON numbers in all but rare spellings; anything else is kept exact as a string.
    private static void WriteNumber(Utf8JsonWriter writer, string number)
    {
        if (JsonNumberPattern().IsMatch(number))
        {
            writer.WriteRawValue(number, skipInputValidation: true);
        }
        else
        {
            writer.WriteStringValue(number);
        }
    }

    [GeneratedRegex(@"^[+-]?(\d+\.?\d*|\.\d+)([eE][+-]?\d+)?$", RegexOptions.CultureInvariant)]
    private static partial Regex NumberPattern();

    [GeneratedRegex(@"^-?(0|[1-9]\d*)(\.\d+)?([eE][+-]?\d+)?$", RegexOptions.CultureInvariant)]
    private static partial Regex JsonNumberPattern();
}
