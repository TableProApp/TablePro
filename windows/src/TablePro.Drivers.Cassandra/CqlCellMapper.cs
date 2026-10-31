using System.Buffers;
using System.Collections;
using System.Globalization;
using System.Net;
using System.Numerics;
using System.Runtime.CompilerServices;
using System.Text;
using System.Text.Encodings.Web;
using System.Text.Json;
using Cassandra;

namespace TablePro.Drivers.Cassandra;

/// <summary>
/// Turns what the driver decodes into the values the grid shows and edits. Scalars stay native; collections, tuples
/// and user-defined types become JSON text in the shape CQL's <c>fromJson()</c> reads back, so an edited cell
/// round-trips through the server's own parser.
/// </summary>
public static class CqlCellMapper
{
    private static readonly JsonWriterOptions WriterOptions = new() { Encoder = JavaScriptEncoder.UnsafeRelaxedJsonEscaping };

    public static Type ClrTypeFor(ColumnTypeCode code) => code switch
    {
        ColumnTypeCode.Ascii or ColumnTypeCode.Text or ColumnTypeCode.Varchar or ColumnTypeCode.Inet or ColumnTypeCode.Duration => typeof(string),
        ColumnTypeCode.Bigint or ColumnTypeCode.Counter => typeof(long),
        ColumnTypeCode.Int => typeof(int),
        ColumnTypeCode.SmallInt => typeof(short),
        ColumnTypeCode.TinyInt => typeof(sbyte),
        ColumnTypeCode.Boolean => typeof(bool),
        ColumnTypeCode.Double => typeof(double),
        ColumnTypeCode.Float => typeof(float),
        ColumnTypeCode.Decimal => typeof(decimal),
        ColumnTypeCode.Varint => typeof(BigInteger),
        ColumnTypeCode.Uuid or ColumnTypeCode.Timeuuid => typeof(Guid),
        ColumnTypeCode.Timestamp => typeof(DateTimeOffset),
        ColumnTypeCode.Date => typeof(DateOnly),
        ColumnTypeCode.Time => typeof(TimeOnly),
        ColumnTypeCode.Blob => typeof(byte[]),
        _ => typeof(string),
    };

    public static object? ToCell(object? value) => value switch
    {
        null => null,
        string or bool or int or long or short or sbyte or byte or double or float or decimal or BigInteger or Guid or byte[] or DateOnly or TimeOnly => value,
        DateTimeOffset dto => dto.ToUniversalTime(),
        DateTime dt => new DateTimeOffset(DateTime.SpecifyKind(dt, DateTimeKind.Utc)),
        TimeUuid timeUuid => timeUuid.ToGuid(),
        IPAddress address => address.ToString(),
        LocalDate date => ToDateOnly(date),
        LocalTime time => new TimeOnly(time.TotalNanoseconds / 100),
        Duration duration => duration.ToString(),
        _ when IsComposite(value) => ToJson(value),
        _ => Convert.ToString(value, CultureInfo.InvariantCulture),
    };

    /// <summary>JSON text for any decoded value, scalars included.</summary>
    public static string ToJson(object? value)
    {
        var buffer = new ArrayBufferWriter<byte>(128);
        using (var writer = new Utf8JsonWriter(buffer, WriterOptions))
        {
            Write(writer, value);
        }

        return Encoding.UTF8.GetString(buffer.WrittenSpan);
    }

    /// <summary>The timestamp text Cassandra parses in every release: milliseconds and a numeric UTC offset.</summary>
    public static string FormatTimestamp(DateTimeOffset value) =>
        value.UtcDateTime.ToString("yyyy-MM-dd HH:mm:ss.fff", CultureInfo.InvariantCulture) + "+0000";

    internal static bool IsComposite(object value) =>
        value is not (string or byte[]) && (value is CqlUdtValue or CqlTupleValue or CqlMapValue or IDictionary or ITuple or IEnumerable);

    private static object ToDateOnly(LocalDate date) =>
        date.Year is >= 1 and <= 9999 ? new DateOnly(date.Year, date.Month, date.Day) : date.ToString();

    private static void Write(Utf8JsonWriter writer, object? value)
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
            case int or long or short or sbyte or byte:
                writer.WriteNumberValue(Convert.ToInt64(value, CultureInfo.InvariantCulture));
                break;
            case double d:
                WriteFloating(writer, d);
                break;
            case float f:
                WriteFloating(writer, f);
                break;
            case decimal m:
                writer.WriteNumberValue(m);
                break;
            case BigInteger big:
                writer.WriteRawValue(big.ToString(CultureInfo.InvariantCulture), skipInputValidation: true);
                break;
            case Guid g:
                writer.WriteStringValue(g.ToString());
                break;
            case TimeUuid t:
                writer.WriteStringValue(t.ToGuid().ToString());
                break;
            case DateTimeOffset dto:
                writer.WriteStringValue(FormatTimestamp(dto));
                break;
            case DateTime dt:
                writer.WriteStringValue(FormatTimestamp(new DateTimeOffset(DateTime.SpecifyKind(dt, DateTimeKind.Utc))));
                break;
            case DateOnly date:
                writer.WriteStringValue(date.ToString("yyyy-MM-dd", CultureInfo.InvariantCulture));
                break;
            case TimeOnly time:
                writer.WriteStringValue(time.ToString("HH:mm:ss.fffffff", CultureInfo.InvariantCulture));
                break;
            case byte[] bytes:
                writer.WriteStringValue("0x" + Convert.ToHexStringLower(bytes));
                break;
            case CqlUdtValue udt:
                writer.WriteStartObject();
                foreach (var (name, field) in udt.Fields)
                {
                    writer.WritePropertyName(name);
                    Write(writer, field);
                }

                writer.WriteEndObject();
                break;
            case CqlMapValue map:
                writer.WriteStartObject();
                foreach (var (key, item) in map.Entries)
                {
                    writer.WritePropertyName(KeyText(key));
                    Write(writer, item);
                }

                writer.WriteEndObject();
                break;
            case IDictionary dictionary:
                writer.WriteStartObject();
                foreach (DictionaryEntry entry in dictionary)
                {
                    writer.WritePropertyName(KeyText(entry.Key));
                    Write(writer, entry.Value);
                }

                writer.WriteEndObject();
                break;
            case CqlTupleValue tuple:
                writer.WriteStartArray();
                foreach (var element in tuple.Elements)
                {
                    Write(writer, element);
                }

                writer.WriteEndArray();
                break;
            case ITuple tuple:
                writer.WriteStartArray();
                for (var i = 0; i < tuple.Length; i++)
                {
                    Write(writer, tuple[i]);
                }

                writer.WriteEndArray();
                break;
            case IEnumerable items:
                writer.WriteStartArray();
                foreach (var item in items)
                {
                    Write(writer, item);
                }

                writer.WriteEndArray();
                break;
            default:
                writer.WriteStringValue(Convert.ToString(ToCell(value) ?? value, CultureInfo.InvariantCulture));
                break;
        }
    }

    private static void WriteFloating(Utf8JsonWriter writer, double value)
    {
        // JSON has no NaN or Infinity; Cassandra's toJson writes them as strings, and fromJson reads them back.
        if (double.IsFinite(value))
        {
            writer.WriteNumberValue(value);
        }
        else
        {
            writer.WriteStringValue(value.ToString(CultureInfo.InvariantCulture));
        }
    }

    // A JSON object key is a string. A text key is itself; any other key is written as its JSON form, which
    // fromJson decodes again for a map whose key type is not text.
    private static string KeyText(object? key)
    {
        if (key is string s)
        {
            return s;
        }

        var json = ToJson(key);
        if (json.Length < 2 || json[0] != '"')
        {
            return json;
        }

        using var document = JsonDocument.Parse(json);
        return document.RootElement.GetString() ?? json;
    }
}
