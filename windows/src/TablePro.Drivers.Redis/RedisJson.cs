using System.Buffers;
using System.Globalization;
using System.Text;
using System.Text.Encodings.Web;
using System.Text.Json;

namespace TablePro.Drivers.Redis;

/// <summary>Writes nested replies and stream entries as compact JSON text for a single grid cell.</summary>
internal static class RedisJson
{
    private static readonly JsonWriterOptions Options = new() { Encoder = JavaScriptEncoder.UnsafeRelaxedJsonEscaping };

    public static string Write(RedisReply reply)
    {
        var buffer = new ArrayBufferWriter<byte>();
        using (var writer = new Utf8JsonWriter(buffer, Options))
        {
            WriteValue(writer, reply);
        }

        return Encoding.UTF8.GetString(buffer.WrittenSpan);
    }

    /// <summary>A stream entry's field list, <c>[f1, v1, f2, v2]</c>, as one JSON object.</summary>
    public static string WriteFields(IReadOnlyList<RedisReply> fieldsAndValues)
    {
        var buffer = new ArrayBufferWriter<byte>();
        using (var writer = new Utf8JsonWriter(buffer, Options))
        {
            writer.WriteStartObject();
            for (var i = 0; i + 1 < fieldsAndValues.Count; i += 2)
            {
                writer.WritePropertyName(fieldsAndValues[i].Text ?? string.Empty);
                WriteValue(writer, fieldsAndValues[i + 1]);
            }

            writer.WriteEndObject();
        }

        return Encoding.UTF8.GetString(buffer.WrittenSpan);
    }

    /// <summary>Encodes text as a JSON string literal, for values written back to ReJSON.</summary>
    public static string Quote(string text)
    {
        var buffer = new ArrayBufferWriter<byte>();
        using (var writer = new Utf8JsonWriter(buffer, Options))
        {
            writer.WriteStringValue(text);
        }

        return Encoding.UTF8.GetString(buffer.WrittenSpan);
    }

    /// <summary>Reads a JSON object of field names to values into a flat list, the shape XADD takes.</summary>
    public static IReadOnlyList<KeyValuePair<string, string>> ReadFields(string json)
    {
        using var document = JsonDocument.Parse(json);
        if (document.RootElement.ValueKind != JsonValueKind.Object)
        {
            throw new FormatException("Stream fields must be a JSON object such as {\"field\": \"value\"}.");
        }

        var fields = new List<KeyValuePair<string, string>>();
        foreach (var property in document.RootElement.EnumerateObject())
        {
            var value = property.Value.ValueKind == JsonValueKind.String ? property.Value.GetString() ?? string.Empty : property.Value.GetRawText();
            fields.Add(new(property.Name, value));
        }

        return fields;
    }

    private static void WriteValue(Utf8JsonWriter writer, RedisReply reply)
    {
        switch (reply.Kind)
        {
            case RedisReplyKind.Null:
                writer.WriteNullValue();
                break;
            case RedisReplyKind.Integer when long.TryParse(reply.Text, NumberStyles.Integer, CultureInfo.InvariantCulture, out var integer):
                writer.WriteNumberValue(integer);
                break;
            case RedisReplyKind.Double when double.TryParse(reply.Text, NumberStyles.Float, CultureInfo.InvariantCulture, out var number) && double.IsFinite(number):
                writer.WriteNumberValue(number);
                break;
            case RedisReplyKind.Boolean:
                writer.WriteBooleanValue(reply.Text == "true");
                break;
            case RedisReplyKind.Error:
                writer.WriteStringValue("(error) " + reply.Text);
                break;
            case RedisReplyKind.Map:
                writer.WriteStartObject();
                for (var i = 0; i + 1 < reply.Items.Count; i += 2)
                {
                    writer.WritePropertyName(reply.Items[i].IsAggregate ? Write(reply.Items[i]) : reply.Items[i].Text ?? string.Empty);
                    WriteValue(writer, reply.Items[i + 1]);
                }

                writer.WriteEndObject();
                break;
            case RedisReplyKind.Array or RedisReplyKind.Set:
                writer.WriteStartArray();
                foreach (var item in reply.Items)
                {
                    WriteValue(writer, item);
                }

                writer.WriteEndArray();
                break;
            default:
                writer.WriteStringValue(reply.Text);
                break;
        }
    }
}
