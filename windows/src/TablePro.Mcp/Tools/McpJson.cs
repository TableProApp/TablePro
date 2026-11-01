using System.Buffers;
using System.Globalization;
using System.Numerics;
using System.Text;
using System.Text.Encodings.Web;
using System.Text.Json;
using TablePro.Core.Results;

namespace TablePro.Mcp.Tools;

/// <summary>Writes tool answers with <see cref="Utf8JsonWriter"/>: no reflection, so the library stays trimmable.</summary>
internal static class McpJson
{
    // A tool's text is read by a model, not embedded in HTML, so non-ASCII stays readable instead of \u-escaped.
    public static readonly JsonWriterOptions WriterOptions = new() { Encoder = JavaScriptEncoder.UnsafeRelaxedJsonEscaping };

    public static string Write(Action<Utf8JsonWriter> write)
    {
        var buffer = new ArrayBufferWriter<byte>(1024);
        using (var writer = new Utf8JsonWriter(buffer, WriterOptions))
        {
            write(writer);
        }

        return Encoding.UTF8.GetString(buffer.WrittenSpan);
    }

    public static void WriteResultSet(Utf8JsonWriter writer, ResultSet set, int maxRows, int maxCellChars)
    {
        writer.WriteStartObject();
        writer.WriteStartArray("columns");
        foreach (var column in set.Columns)
        {
            writer.WriteStartObject();
            writer.WriteString("name", column.Name);
            writer.WriteString("type", column.DataType);
            writer.WriteEndObject();
        }

        writer.WriteEndArray();

        var rows = Math.Min(set.RowCount, maxRows);
        writer.WriteStartArray("rows");
        for (var r = 0; r < rows; r++)
        {
            var row = set.Rows[r];
            writer.WriteStartArray();
            for (var c = 0; c < set.Columns.Count; c++)
            {
                WriteValue(writer, c < row.Length ? row[c] : null, maxCellChars);
            }

            writer.WriteEndArray();
        }

        writer.WriteEndArray();
        writer.WriteNumber("row_count", rows);
        writer.WriteBoolean("truncated", set.IsTruncated || set.RowCount > maxRows);
        writer.WriteEndObject();
    }

    public static void WriteValue(Utf8JsonWriter writer, object? value, int maxCellChars)
    {
        switch (value)
        {
            case null or DBNull:
                writer.WriteNullValue();
                break;
            case bool b:
                writer.WriteBooleanValue(b);
                break;
            case string s:
                writer.WriteStringValue(Cap(s, maxCellChars));
                break;
            case int i:
                writer.WriteNumberValue(i);
                break;
            case long l:
                writer.WriteNumberValue(l);
                break;
            case short sh:
                writer.WriteNumberValue(sh);
                break;
            case byte by:
                writer.WriteNumberValue(by);
                break;
            case sbyte sb:
                writer.WriteNumberValue(sb);
                break;
            case ushort us:
                writer.WriteNumberValue(us);
                break;
            case uint ui:
                writer.WriteNumberValue(ui);
                break;
            case ulong ul:
                writer.WriteNumberValue(ul);
                break;
            case decimal m:
                writer.WriteNumberValue(m);
                break;

            // JSON has no NaN or Infinity.
            case double d when double.IsFinite(d):
                writer.WriteNumberValue(d);
                break;
            case float f when float.IsFinite(f):
                writer.WriteNumberValue(f);
                break;
            case double or float:
                writer.WriteStringValue(Convert.ToString(value, CultureInfo.InvariantCulture));
                break;
            case BigInteger big:
                writer.WriteStringValue(big.ToString(CultureInfo.InvariantCulture));
                break;
            case DateTime dt:
                writer.WriteStringValue(dt.ToString(dt.TimeOfDay == TimeSpan.Zero && dt.Kind == DateTimeKind.Unspecified ? "yyyy-MM-dd" : "O", CultureInfo.InvariantCulture));
                break;
            case DateTimeOffset dto:
                writer.WriteStringValue(dto.ToString("O", CultureInfo.InvariantCulture));
                break;
            case DateOnly date:
                writer.WriteStringValue(date.ToString("yyyy-MM-dd", CultureInfo.InvariantCulture));
                break;
            case TimeOnly time:
                writer.WriteStringValue(time.ToString("HH:mm:ss.FFFFFFF", CultureInfo.InvariantCulture));
                break;
            case TimeSpan span:
                writer.WriteStringValue(span.ToString("c", CultureInfo.InvariantCulture));
                break;
            case Guid guid:
                writer.WriteStringValue(guid);
                break;
            case byte[] bytes:
                var shown = Math.Min(bytes.Length, Math.Max(1, maxCellChars / 2));
                writer.WriteStringValue(string.Concat("0x", Convert.ToHexString(bytes, 0, shown), shown < bytes.Length ? "..." : string.Empty));
                break;
            default:
                writer.WriteStringValue(Cap(CellFormatter.Format(value), maxCellChars));
                break;
        }
    }

    private static string Cap(string text, int maxChars) =>
        text.Length <= maxChars ? text : string.Concat(text.AsSpan(0, char.IsHighSurrogate(text[maxChars - 1]) ? maxChars - 1 : maxChars), "...");
}
