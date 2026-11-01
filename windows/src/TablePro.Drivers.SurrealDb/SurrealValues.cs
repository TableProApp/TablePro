using System.Globalization;
using System.Text;
using System.Text.Json;
using TablePro.Drivers.Http;

namespace TablePro.Drivers.SurrealDb;

/// <summary>A SurrealDB object with its fields in the order the server sent them.</summary>
internal sealed class SurrealObject(int capacity = 4)
{
    private readonly List<KeyValuePair<string, object?>> _fields = new(capacity);

    public IReadOnlyList<KeyValuePair<string, object?>> Fields => _fields;

    public void Add(string name, object? value) => _fields.Add(new(name, value));

    public bool TryGetValue(string name, out object? value)
    {
        foreach (var (key, field) in _fields)
        {
            if (key == name)
            {
                value = field;
                return true;
            }
        }

        value = null;
        return false;
    }
}

/// <summary>A record id as the RPC protocol sends it, shown and written back as SurrealQL such as <c>person:tobie</c>.</summary>
internal sealed record SurrealRecord(string Table, object? Id)
{
    public override string ToString() => SurrealValues.RecordLiteral(this);
}

/// <summary>A duration in SurrealQL's own spelling, such as <c>1h30m</c>, which TimeSpan cannot hold beyond days.</summary>
internal sealed record SurrealDuration(string Text)
{
    public override string ToString() => Text;
}

internal sealed record SurrealBound(object? Value, bool IsInclusive);

internal sealed record SurrealRange(SurrealBound? From, SurrealBound? To)
{
    public override string ToString() =>
        string.Concat(
            From is null ? string.Empty : SurrealValues.Text(From.Value),
            From is null or { IsInclusive: true } ? ".." : ">..",
            To is { IsInclusive: true } ? "=" : string.Empty,
            To is null ? string.Empty : SurrealValues.Text(To.Value));
}

/// <summary>A GeoJSON shape; the tag says which, from Point (88) to GeometryCollection (94).</summary>
internal sealed record SurrealGeometry(ulong Tag, object? Value)
{
    public string TypeName => Tag switch
    {
        88 => "Point",
        89 => "LineString",
        90 => "Polygon",
        91 => "MultiPoint",
        92 => "MultiLineString",
        93 => "MultiPolygon",
        _ => "GeometryCollection",
    };
}

/// <summary>
/// Turns SurrealDB values, from the RPC's CBOR or from the JSON of <c>/sql</c>, into grid cells and JSON text. Values
/// the grid has a type for (datetimes, decimals, numbers, booleans) stay typed; records, durations and ranges become
/// their SurrealQL text; objects and arrays become JSON.
/// </summary>
internal static class SurrealValues
{
    private static readonly long MinUnixSeconds = DateTimeOffset.MinValue.ToUnixTimeSeconds();
    private static readonly long MaxUnixSeconds = DateTimeOffset.MaxValue.ToUnixTimeSeconds();

    /// <summary>A decimal's text as a decimal, or the text when it is beyond what decimal holds.</summary>
    public static object Decimal(string text)
    {
        var trimmed = text.Trim();
        if (trimmed.EndsWith("dec", StringComparison.Ordinal))
        {
            trimmed = trimmed[..^3];
        }

        return decimal.TryParse(trimmed, NumberStyles.Float, CultureInfo.InvariantCulture, out var value) ? value : text;
    }

    /// <summary>An RFC 3339 datetime as a DateTimeOffset in UTC, or the text when it does not parse or fit.</summary>
    public static object Datetime(string text) =>
        DateTimeOffset.TryParse(text, CultureInfo.InvariantCulture, DateTimeStyles.AssumeUniversal | DateTimeStyles.AdjustToUniversal, out var value) ? value : text;

    /// <summary>
    /// Seconds and nanoseconds since the epoch. DateTimeOffset keeps 100 ns ticks and years 1 to 9999, the range a
    /// grid shows; a datetime outside it stays text rather than being clamped.
    /// </summary>
    public static object Datetime(long seconds, long nanoseconds)
    {
        if (seconds >= MinUnixSeconds && seconds <= MaxUnixSeconds)
        {
            var ticks = (seconds * TimeSpan.TicksPerSecond) + (nanoseconds / 100);
            var utc = DateTimeOffset.UnixEpoch.Ticks + ticks;
            if (utc >= DateTimeOffset.MinValue.Ticks && utc <= DateTimeOffset.MaxValue.Ticks)
            {
                return new DateTimeOffset(utc, TimeSpan.Zero);
            }
        }

        return string.Create(CultureInfo.InvariantCulture, $"{seconds}s {nanoseconds}ns since 1970-01-01T00:00:00Z");
    }

    /// <summary>SurrealQL's duration spelling, largest unit first: <c>1w2d3h4m5s6ms</c>.</summary>
    public static string FormatDuration(long seconds, long nanoseconds)
    {
        if (seconds == 0 && nanoseconds == 0)
        {
            return "0ns";
        }

        var text = new StringBuilder();
        var remaining = seconds;
        foreach (var (size, suffix) in new (long, string)[] { (604_800, "w"), (86_400, "d"), (3_600, "h"), (60, "m"), (1, "s") })
        {
            if (remaining >= size)
            {
                text.Append(CultureInfo.InvariantCulture, $"{remaining / size}{suffix}");
                remaining %= size;
            }
        }

        foreach (var (size, suffix) in new (long, string)[] { (1_000_000, "ms"), (1_000, "\xB5s"), (1, "ns") })
        {
            if (nanoseconds >= size)
            {
                text.Append(CultureInfo.InvariantCulture, $"{nanoseconds / size}{suffix}");
                nanoseconds %= size;
            }
        }

        return text.ToString();
    }

    /// <summary>
    /// A record id in the spelling <see cref="SurrealRecordId.Parse"/> reads back: a plain id as it is, any other text
    /// in angle brackets, and an array, object or uuid id in its own syntax, which only the server reads.
    /// </summary>
    public static string RecordLiteral(SurrealRecord record)
    {
        var table = IsSimpleIdentifier(record.Table) ? record.Table : SurrealQl.Ident(record.Table);
        var id = record.Id switch
        {
            long number => number.ToString(CultureInfo.InvariantCulture),
            string text when IsSimpleIdentifier(text) => text,
            string text => string.Concat("\x27E8", text.Replace("\\", "\\\\", StringComparison.Ordinal).Replace("\x27E9", "\\\x27E9", StringComparison.Ordinal), "\x27E9"),
            Guid uuid => string.Concat("u\"", uuid.ToString(), "\""),
            var other => ToJson(other),
        };

        return string.Concat(table, ":", id);
    }

    public static object? FromJson(JsonElement value)
    {
        switch (value.ValueKind)
        {
            case JsonValueKind.String:
                return value.GetString();
            case JsonValueKind.Number:
                return JsonCells.Number(value);
            case JsonValueKind.True:
                return true;
            case JsonValueKind.False:
                return false;
            case JsonValueKind.Array:
            {
                var items = new List<object?>(value.GetArrayLength());
                foreach (var item in value.EnumerateArray())
                {
                    items.Add(FromJson(item));
                }

                return items;
            }

            case JsonValueKind.Object:
            {
                var fields = new SurrealObject();
                foreach (var property in value.EnumerateObject())
                {
                    fields.Add(property.Name, FromJson(property.Value));
                }

                return fields;
            }

            default:
                return null;
        }
    }

    /// <summary>A grid cell: scalars keep their type, anything structured becomes its JSON text.</summary>
    public static object? ToCell(object? value) => value switch
    {
        null or bool or long or double or decimal or string or byte[] or DateTimeOffset => value,
        Guid uuid => uuid.ToString(),
        SurrealRecord or SurrealDuration or SurrealRange => value.ToString(),
        _ => ToJson(value),
    };

    /// <summary>The text of a value, as a range bound or a record id shows it.</summary>
    public static string Text(object? value) => value switch
    {
        null => string.Empty,
        string text => text,
        DateTimeOffset dto => Iso(dto),
        IFormattable formattable when value is not (SurrealObject or List<object?>) => formattable.ToString(null, CultureInfo.InvariantCulture),
        SurrealRecord or SurrealDuration or SurrealRange => value.ToString() ?? string.Empty,
        Guid uuid => uuid.ToString(),
        _ => ToJson(value),
    };

    /// <summary>The SurrealDB type a value has, for the column of a schemaless field.</summary>
    public static string KindName(object? value) => value switch
    {
        long => "int",
        double => "float",
        decimal => "decimal",
        bool => "bool",
        string => "string",
        DateTimeOffset => "datetime",
        Guid => "uuid",
        byte[] => "bytes",
        SurrealRecord => "record",
        SurrealDuration => "duration",
        SurrealGeometry => "geometry",
        SurrealObject => "object",
        List<object?> => "array",
        _ => "any",
    };

    /// <summary>
    /// A cell read for a declared field, in the field's type. <c>/sql</c>'s JSON spells a datetime and a decimal as
    /// text, which the declaration says how to read; the RPC already sends them typed and passes through.
    /// </summary>
    public static object? Coerce(object? cell, SurrealKind? kind) => (kind?.Base, cell) switch
    {
        ("datetime", string text) => Datetime(text),
        ("decimal", string text) => Decimal(text),
        ("decimal", long number) => (decimal)number,
        ("decimal", double number) when double.IsFinite(number) && Math.Abs(number) < 7.9e28 => (decimal)number,
        _ => cell,
    };

    /// <summary>
    /// Declares the columns whose every value has one type the grid knows, so a query's datetimes and decimals sort,
    /// format and edit as such.
    /// </summary>
    public static void DeclareTypedColumns(DocumentTable table, IReadOnlyList<SurrealObject> rows)
    {
        var kinds = new Dictionary<string, Type?>(StringComparer.Ordinal);
        foreach (var row in rows)
        {
            foreach (var (name, value) in row.Fields)
            {
                var type = value switch
                {
                    DateTimeOffset => typeof(DateTimeOffset),
                    decimal => typeof(decimal),
                    null => null,
                    _ => typeof(object),
                };

                if (type is null)
                {
                    kinds.TryAdd(name, null);
                }
                else if (!kinds.TryGetValue(name, out var seen) || seen is null)
                {
                    kinds[name] = type;
                }
                else if (seen != type)
                {
                    kinds[name] = typeof(object);
                }
            }
        }

        foreach (var (name, type) in kinds)
        {
            if (type == typeof(DateTimeOffset))
            {
                table.Declare(name, "datetime", type);
            }
            else if (type == typeof(decimal))
            {
                table.Declare(name, "decimal", type);
            }
        }
    }

    public static string ToJson(object? value)
    {
        using var stream = new MemoryStream();
        using (var writer = new Utf8JsonWriter(stream, JsonCells.Compact))
        {
            Write(writer, value);
        }

        return Encoding.UTF8.GetString(stream.GetBuffer(), 0, (int)stream.Length);
    }

    /// <summary>
    /// JSON as <c>/sql</c> would have written it, so the catalog code reads RPC answers unchanged: a datetime as its
    /// RFC 3339 text, a record as <c>table:id</c>, NONE as null, a shape as GeoJSON.
    /// </summary>
    public static void Write(Utf8JsonWriter writer, object? value)
    {
        switch (value)
        {
            case null:
                writer.WriteNullValue();
                break;
            case bool flag:
                writer.WriteBooleanValue(flag);
                break;
            case long number:
                writer.WriteNumberValue(number);
                break;
            case double number when double.IsFinite(number):
                writer.WriteNumberValue(number);
                break;
            case double number:
                writer.WriteStringValue(number.ToString(CultureInfo.InvariantCulture));
                break;
            case decimal number:
                writer.WriteNumberValue(number);
                break;
            case string text:
                writer.WriteStringValue(text);
                break;
            case byte[] bytes:
                writer.WriteBase64StringValue(bytes);
                break;
            case DateTimeOffset dto:
                writer.WriteStringValue(Iso(dto));
                break;
            case Guid uuid:
                writer.WriteStringValue(uuid.ToString());
                break;
            case List<object?> items:
                writer.WriteStartArray();
                foreach (var item in items)
                {
                    Write(writer, item);
                }

                writer.WriteEndArray();
                break;
            case SurrealObject fields:
                writer.WriteStartObject();
                foreach (var (name, field) in fields.Fields)
                {
                    writer.WritePropertyName(name);
                    Write(writer, field);
                }

                writer.WriteEndObject();
                break;
            case SurrealGeometry geometry:
                writer.WriteStartObject();
                writer.WriteString("type", geometry.TypeName);
                if (geometry.Tag == SurrealCbor.TagGeometryCollection)
                {
                    writer.WritePropertyName("geometries");
                    Write(writer, geometry.Value);
                }
                else
                {
                    writer.WritePropertyName("coordinates");
                    WriteCoordinates(writer, geometry.Value);
                }

                writer.WriteEndObject();
                break;
            default:
                writer.WriteStringValue(Text(value));
                break;
        }
    }

    // A shape's points arrive as Point shapes of their own; GeoJSON nests only their coordinates.
    private static void WriteCoordinates(Utf8JsonWriter writer, object? value)
    {
        switch (value)
        {
            case SurrealGeometry inner:
                WriteCoordinates(writer, inner.Value);
                break;
            case List<object?> items:
                writer.WriteStartArray();
                foreach (var item in items)
                {
                    WriteCoordinates(writer, item);
                }

                writer.WriteEndArray();
                break;
            default:
                Write(writer, value);
                break;
        }
    }

    private static string Iso(DateTimeOffset value) =>
        value.UtcDateTime.ToString("yyyy-MM-dd'T'HH:mm:ss.FFFFFFF'Z'", CultureInfo.InvariantCulture);

    private static bool IsSimpleIdentifier(string name)
    {
        if (name.Length == 0 || char.IsAsciiDigit(name[0]))
        {
            return false;
        }

        foreach (var c in name)
        {
            if (!char.IsAsciiLetterOrDigit(c) && c != '_')
            {
                return false;
            }
        }

        return true;
    }
}
