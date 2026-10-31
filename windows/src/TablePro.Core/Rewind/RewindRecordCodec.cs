using System.Globalization;
using System.Numerics;
using System.Text.Json;
using TablePro.Core.Connections;
using TablePro.Core.Localization;
using TablePro.Core.Schema;

namespace TablePro.Core.Rewind;

/// <summary>
/// Writes a <see cref="RewindRecord"/> as JSON with every value's CLR type kept, so a restored row binds the same
/// <see cref="int"/>, <see cref="Guid"/> or <see cref="DateTime"/> the grid read rather than a string the engine has
/// to convert. Written by hand over <see cref="Utf8JsonWriter"/> because the values are untyped, which source
/// generation cannot describe.
/// </summary>
public static class RewindRecordCodec
{
    private const int Version = 1;

    public static byte[] Serialize(RewindRecord record)
    {
        ArgumentNullException.ThrowIfNull(record);
        var buffer = new System.Buffers.ArrayBufferWriter<byte>(1024);
        using (var writer = new Utf8JsonWriter(buffer))
        {
            writer.WriteStartObject();
            writer.WriteNumber("v", Version);
            writer.WriteString("id", record.Id);
            writer.WriteString("connection", record.ConnectionId);
            writer.WriteString("engine", record.Engine.ToString());
            WriteNullable(writer, "database", record.Database);
            WriteNullable(writer, "schema", record.Table.Schema);
            writer.WriteString("table", record.Table.Name);
            writer.WriteString("at", record.CapturedAt);
            if (record.Restores is { } restores)
            {
                writer.WriteString("restores", restores);
            }

            WriteStrings(writer, "columns", record.Columns);
            WriteStrings(writer, "key", record.PrimaryKey);
            writer.WriteStartArray("ops");
            foreach (var operation in record.Operations)
            {
                writer.WriteStartObject();
                writer.WriteString("k", operation.Kind.ToString());
                if (operation.Refusal is { } refusal)
                {
                    writer.WriteString("refused", refusal.ToString());
                }

                WriteRow(writer, "before", operation.Before);
                WriteRow(writer, "after", operation.After);
                WriteStrings(writer, "written", operation.Written);
                writer.WriteEndObject();
            }

            writer.WriteEndArray();
            writer.WriteEndObject();
        }

        return buffer.WrittenSpan.ToArray();
    }

    /// <exception cref="JsonException">The payload is not a record this build can read.</exception>
    public static RewindRecord Deserialize(ReadOnlySpan<byte> json)
    {
        var reader = new Utf8JsonReader(json);
        using var document = JsonDocument.ParseValue(ref reader);
        var root = document.RootElement;
        if (root.GetProperty("v").GetInt32() > Version)
        {
            throw new JsonException(CoreStrings.Get("Rewind/RecordedByNewerVersion"));
        }

        var operations = root.GetProperty("ops").EnumerateArray().Select(op => new RewindOperation(
            Enum.Parse<RewindOperationKind>(op.GetProperty("k").GetString()!),
            ReadRow(op, "before"),
            ReadRow(op, "after"),
            ReadStrings(op.GetProperty("written")),
            op.TryGetProperty("refused", out var refused) ? Enum.Parse<RewindRefusal>(refused.GetString()!) : null)).ToArray();

        return new RewindRecord(
            root.GetProperty("id").GetGuid(),
            root.GetProperty("connection").GetGuid(),
            Enum.Parse<DatabaseEngine>(root.GetProperty("engine").GetString()!),
            ReadNullable(root, "database"),
            new ObjectName(ReadNullable(root, "schema"), root.GetProperty("table").GetString()!),
            root.GetProperty("at").GetDateTimeOffset(),
            ReadStrings(root.GetProperty("columns")),
            ReadStrings(root.GetProperty("key")),
            operations)
        {
            Restores = root.TryGetProperty("restores", out var restores) ? restores.GetGuid() : null,
        };
    }

    private static void WriteNullable(Utf8JsonWriter writer, string name, string? value)
    {
        if (value is null)
        {
            writer.WriteNull(name);
        }
        else
        {
            writer.WriteString(name, value);
        }
    }

    private static string? ReadNullable(JsonElement element, string name) =>
        element.TryGetProperty(name, out var value) && value.ValueKind == JsonValueKind.String ? value.GetString() : null;

    private static void WriteStrings(Utf8JsonWriter writer, string name, IReadOnlyList<string> values)
    {
        writer.WriteStartArray(name);
        foreach (var value in values)
        {
            writer.WriteStringValue(value);
        }

        writer.WriteEndArray();
    }

    private static string[] ReadStrings(JsonElement array) => [.. array.EnumerateArray().Select(e => e.GetString() ?? string.Empty)];

    private static void WriteRow(Utf8JsonWriter writer, string name, object?[]? row)
    {
        if (row is null)
        {
            return;
        }

        writer.WriteStartArray(name);
        foreach (var value in row)
        {
            WriteValue(writer, value);
        }

        writer.WriteEndArray();
    }

    private static object?[]? ReadRow(JsonElement operation, string name)
    {
        if (!operation.TryGetProperty(name, out var array) || array.ValueKind != JsonValueKind.Array)
        {
            return null;
        }

        var row = new object?[array.GetArrayLength()];
        var i = 0;
        foreach (var value in array.EnumerateArray())
        {
            row[i++] = ReadValue(value);
        }

        return row;
    }

    // A value is null or a pair [type, text]: the text alone would lose whether 1 was an int, a long or a decimal.
    private static void WriteValue(Utf8JsonWriter writer, object? value)
    {
        if (value is null or DBNull)
        {
            writer.WriteNullValue();
            return;
        }

        var (tag, text) = value switch
        {
            string s => ("s", s),
            bool b => ("b", b ? "1" : "0"),
            int i => ("i4", Invariant(i)),
            long l => ("i8", Invariant(l)),
            short s => ("i2", Invariant(s)),
            byte b => ("u1", Invariant(b)),
            sbyte b => ("i1", Invariant(b)),
            ushort u => ("u2", Invariant(u)),
            uint u => ("u4", Invariant(u)),
            ulong u => ("u8", Invariant(u)),
            decimal m => ("m", Invariant(m)),
            double d => ("f8", d.ToString("R", CultureInfo.InvariantCulture)),
            float f => ("f4", f.ToString("R", CultureInfo.InvariantCulture)),
            DateTime dt => ("dt", dt.ToString("O", CultureInfo.InvariantCulture)),
            DateTimeOffset dto => ("dto", dto.ToString("O", CultureInfo.InvariantCulture)),
            DateOnly d => ("date", d.ToString("O", CultureInfo.InvariantCulture)),
            TimeOnly t => ("time", t.ToString("O", CultureInfo.InvariantCulture)),
            TimeSpan ts => ("ts", ts.ToString("c", CultureInfo.InvariantCulture)),
            Guid g => ("g", g.ToString("D")),
            byte[] bytes => ("x", Convert.ToBase64String(bytes)),
            BigInteger n => ("n", n.ToString(CultureInfo.InvariantCulture)),
            char c => ("s", c.ToString()),
            IFormattable formattable => ("s", formattable.ToString(null, CultureInfo.InvariantCulture)),
            _ => ("s", value.ToString() ?? string.Empty),
        };

        writer.WriteStartArray();
        writer.WriteStringValue(tag);
        writer.WriteStringValue(text);
        writer.WriteEndArray();
    }

    private static object? ReadValue(JsonElement value)
    {
        if (value.ValueKind != JsonValueKind.Array)
        {
            return null;
        }

        var tag = value[0].GetString();
        var text = value[1].GetString() ?? string.Empty;
        var c = CultureInfo.InvariantCulture;
        return tag switch
        {
            "s" => text,
            "b" => text == "1",
            "i4" => int.Parse(text, c),
            "i8" => long.Parse(text, c),
            "i2" => short.Parse(text, c),
            "u1" => byte.Parse(text, c),
            "i1" => sbyte.Parse(text, c),
            "u2" => ushort.Parse(text, c),
            "u4" => uint.Parse(text, c),
            "u8" => ulong.Parse(text, c),
            "m" => decimal.Parse(text, NumberStyles.Number, c),
            "f8" => double.Parse(text, NumberStyles.Float, c),
            "f4" => float.Parse(text, NumberStyles.Float, c),
            "dt" => DateTime.Parse(text, c, DateTimeStyles.RoundtripKind),
            "dto" => DateTimeOffset.Parse(text, c, DateTimeStyles.RoundtripKind),
            "date" => DateOnly.ParseExact(text, "O", c),
            "time" => TimeOnly.ParseExact(text, "O", c),
            "ts" => TimeSpan.ParseExact(text, "c", c),
            "g" => Guid.Parse(text),
            "x" => Convert.FromBase64String(text),
            "n" => BigInteger.Parse(text, c),
            _ => text,
        };
    }

    private static string Invariant<T>(T value)
        where T : IFormattable => value.ToString(null, CultureInfo.InvariantCulture);
}
