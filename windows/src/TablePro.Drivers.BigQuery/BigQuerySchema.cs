using System.Buffers;
using System.Collections;
using System.Globalization;
using System.Text;
using System.Text.Json;
using Google.Apis.Bigquery.v2.Data;
using Google.Cloud.BigQuery.V2;
using TablePro.Core.Localization;
using TablePro.Core.Results;
using TablePro.Core.Schema;

namespace TablePro.Drivers.BigQuery;

/// <summary>One field of a table schema, with nested record fields reached by a dotted path.</summary>
public sealed record BigQueryField(string Path, string Type, bool IsRepeated, bool IsNullable, string? Description, int Depth)
{
    /// <summary>A RECORD or a REPEATED field, whose value the grid shows as JSON.</summary>
    public bool IsComplex => IsRepeated || BigQuerySchema.IsRecord(Type);

    /// <summary>Whether <c>=</c> works on it, so it can identify a row in an UPDATE or DELETE.</summary>
    public bool IsComparable => Depth == 0 && !IsComplex && Type.ToUpperInvariant() is not ("JSON" or "GEOGRAPHY");

    /// <summary>What the structure tab and the result grid name as its type.</summary>
    public string DisplayType => IsComplex ? "JSON" : IsRepeated ? $"ARRAY<{Type}>" : Type;
}

/// <summary>Reading table schemas and row values the way the grid and the editor need them.</summary>
public static class BigQuerySchema
{
    public static bool IsRecord(string type) => type.ToUpperInvariant() is "RECORD" or "STRUCT";

    /// <summary>
    /// Lists top-level fields in order, each RECORD followed by its fields as <c>parent.child</c>. A record and a
    /// repeated field are typed JSON because that is how their values read; their children keep their own types.
    /// </summary>
    public static IReadOnlyList<BigQueryField> Flatten(IEnumerable<TableFieldSchema>? fields)
    {
        var flat = new List<BigQueryField>();
        Add(fields, prefix: null, depth: 0, flat);
        return flat;
    }

    private static void Add(IEnumerable<TableFieldSchema>? fields, string? prefix, int depth, List<BigQueryField> flat)
    {
        if (fields is null)
        {
            return;
        }

        foreach (var field in fields)
        {
            var path = prefix is null ? field.Name : string.Concat(prefix, ".", field.Name);
            var mode = field.Mode?.ToUpperInvariant();
            var type = field.Type ?? "STRING";
            flat.Add(new BigQueryField(path, type, mode == "REPEATED", mode != "REQUIRED", field.Description, depth));
            if (IsRecord(type))
            {
                Add(field.Fields, path, depth + 1, flat);
            }
        }
    }

    public static IReadOnlyList<ColumnInfo> Columns(IReadOnlyList<BigQueryField> fields, IReadOnlyCollection<string> keyColumns)
    {
        var columns = new ColumnInfo[fields.Count];
        for (var i = 0; i < fields.Count; i++)
        {
            var field = fields[i];
            columns[i] = new ColumnInfo(
                field.Path,
                field.DisplayType,
                field.IsNullable,
                null,
                field.Depth == 0 && keyColumns.Contains(field.Path),
                false,
                i,
                field.Description);
        }

        return columns;
    }

    public static Type ClrType(string type, bool repeated) => repeated ? typeof(string) : type.ToUpperInvariant() switch
    {
        "INT64" or "INTEGER" => typeof(long),
        "FLOAT64" or "FLOAT" => typeof(double),
        "NUMERIC" or "BIGNUMERIC" or "DECIMAL" or "BIGDECIMAL" => typeof(decimal),
        "BOOL" or "BOOLEAN" => typeof(bool),
        "BYTES" => typeof(byte[]),
        "DATE" or "DATETIME" or "TIMESTAMP" => typeof(DateTime),
        "TIME" => typeof(TimeSpan),
        _ => typeof(string),
    };

    public static ResultColumn[] ResultColumns(TableSchema? schema) =>
        [.. (schema?.Fields ?? []).Select(f =>
        {
            var repeated = string.Equals(f.Mode, "REPEATED", StringComparison.OrdinalIgnoreCase);
            var complex = repeated || IsRecord(f.Type ?? string.Empty);
            return new ResultColumn(f.Name, complex ? "JSON" : f.Type ?? "STRING", complex ? typeof(string) : ClrType(f.Type ?? string.Empty, false));
        })];

    public static object?[] ReadRow(BigQueryRow row, int fieldCount)
    {
        var values = new object?[fieldCount];
        for (var i = 0; i < fieldCount; i++)
        {
            values[i] = GridValue(row[i]);
        }

        return values;
    }

    /// <summary>Records and arrays become JSON text; numerics become decimal when they fit, else their exact text.</summary>
    public static object? GridValue(object? value) => value switch
    {
        null => null,
        string or long or double or bool or byte[] or DateTime or TimeSpan or DateTimeOffset => value,
        BigQueryNumeric numeric => ToDecimalOrText(numeric.ToString()),
        BigQueryBigNumeric big => ToDecimalOrText(big.ToString()),
        IDictionary or IEnumerable => ToJson(value),
        _ => Convert.ToString(value, CultureInfo.InvariantCulture),
    };

    // decimal holds 28 digits and NUMERIC 38; a value that would lose digits stays exact as text.
    private static object ToDecimalOrText(string text) =>
        decimal.TryParse(text, NumberStyles.Float, CultureInfo.InvariantCulture, out var d)
            && string.Equals(Normalize(d.ToString(CultureInfo.InvariantCulture)), Normalize(text), StringComparison.Ordinal)
            ? d
            : text;

    private static string Normalize(string number) =>
        number.Contains('.', StringComparison.Ordinal) ? number.TrimEnd('0').TrimEnd('.') : number;

    public static string ToJson(object? value)
    {
        var buffer = new ArrayBufferWriter<byte>();
        using (var writer = new Utf8JsonWriter(buffer))
        {
            Write(writer, value);
        }

        return Encoding.UTF8.GetString(buffer.WrittenSpan);
    }

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
            case long l:
                writer.WriteNumberValue(l);
                break;
            case int i:
                writer.WriteNumberValue(i);
                break;
            case double d when double.IsFinite(d):
                writer.WriteNumberValue(d);
                break;
            case double d:
                writer.WriteStringValue(d.ToString(CultureInfo.InvariantCulture));
                break;
            case BigQueryNumeric or BigQueryBigNumeric:
                writer.WriteRawValue(value.ToString()!, skipInputValidation: true);
                break;
            case byte[] bytes:
                writer.WriteBase64StringValue(bytes);
                break;
            case DateTime dt:
                writer.WriteStringValue(dt.ToString(dt.Kind == DateTimeKind.Utc ? "yyyy-MM-dd'T'HH:mm:ss.FFFFFFF'Z'" : "yyyy-MM-dd'T'HH:mm:ss.FFFFFFF", CultureInfo.InvariantCulture));
                break;
            case TimeSpan ts:
                writer.WriteStringValue(ts.ToString("c", CultureInfo.InvariantCulture));
                break;
            case IDictionary<string, object> record:
                writer.WriteStartObject();
                foreach (var (key, item) in record)
                {
                    writer.WritePropertyName(key);
                    Write(writer, item);
                }

                writer.WriteEndObject();
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
                writer.WriteStringValue(Convert.ToString(value, CultureInfo.InvariantCulture));
                break;
        }
    }

    /// <summary>
    /// A query parameter of the column's type. BigQuery compares strictly, so a filter typed into an INT64 column must
    /// reach it as INT64, not as STRING.
    /// </summary>
    public static BigQueryParameter Parameter(string name, string? columnType, object? value)
    {
        var type = (columnType ?? "STRING").ToUpperInvariant();
        var dbType = type switch
        {
            "INT64" or "INTEGER" => BigQueryDbType.Int64,
            "FLOAT64" or "FLOAT" => BigQueryDbType.Float64,
            "NUMERIC" or "DECIMAL" => BigQueryDbType.Numeric,
            "BIGNUMERIC" or "BIGDECIMAL" => BigQueryDbType.BigNumeric,
            "BOOL" or "BOOLEAN" => BigQueryDbType.Bool,
            "BYTES" => BigQueryDbType.Bytes,
            "DATE" => BigQueryDbType.Date,
            "DATETIME" => BigQueryDbType.DateTime,
            "TIME" => BigQueryDbType.Time,
            "TIMESTAMP" => BigQueryDbType.Timestamp,
            "JSON" => BigQueryDbType.Json,
            "GEOGRAPHY" => BigQueryDbType.Geography,
            _ => BigQueryDbType.String,
        };

        return new BigQueryParameter(name, dbType, value is null ? null : ParameterValue(value, dbType, type));
    }

    private static object ParameterValue(object value, BigQueryDbType dbType, string type)
    {
        var inv = CultureInfo.InvariantCulture;
        var text = value as string;
        object? converted = dbType switch
        {
            BigQueryDbType.Int64 => text is null ? System.Convert.ToInt64(value, inv) : long.TryParse(text, NumberStyles.Integer, inv, out var l) ? l : null,
            BigQueryDbType.Float64 => text is null ? System.Convert.ToDouble(value, inv) : double.TryParse(text, NumberStyles.Float, inv, out var d) ? d : null,
            BigQueryDbType.Numeric => TryNumeric(text ?? System.Convert.ToString(value, inv)!),
            BigQueryDbType.BigNumeric => TryBigNumeric(text ?? System.Convert.ToString(value, inv)!),
            BigQueryDbType.Bool => value is bool b ? b : (text ?? string.Empty).Trim().ToUpperInvariant() switch
            {
                "TRUE" or "T" or "1" or "YES" or "Y" => true,
                "FALSE" or "F" or "0" or "NO" or "N" => false,
                _ => null,
            },
            BigQueryDbType.Bytes => value as byte[] ?? FromHexOrBase64(text ?? string.Empty),
            BigQueryDbType.Date => value switch
            {
                DateTime dt => dt.Date,
                DateOnly date => date.ToDateTime(TimeOnly.MinValue),
                _ => DateTime.TryParse(text, inv, System.Globalization.DateTimeStyles.AllowWhiteSpaces, out var parsed) ? parsed.Date : null,
            },
            BigQueryDbType.DateTime => value is DateTime dt2 ? dt2 : DateTime.TryParse(text, inv, System.Globalization.DateTimeStyles.AllowWhiteSpaces, out var parsed2) ? parsed2 : null,
            BigQueryDbType.Time => value switch
            {
                TimeSpan ts => ts,
                TimeOnly time => time.ToTimeSpan(),
                _ => TimeSpan.TryParse(text, inv, out var parsed3) ? parsed3 : null,
            },
            BigQueryDbType.Timestamp => value switch
            {
                DateTimeOffset dto => dto,
                DateTime dt3 => new DateTimeOffset(dt3.Kind == DateTimeKind.Unspecified ? DateTime.SpecifyKind(dt3, DateTimeKind.Utc) : dt3),
                _ => DateTimeOffset.TryParse(text, inv, System.Globalization.DateTimeStyles.AssumeUniversal, out var parsed4) ? parsed4 : null,
            },
            _ => text ?? System.Convert.ToString(value, inv),
        };

        return converted ?? throw new FormatException(CoreStrings.Format("Driver/InvalidTypedValue", value, type));
    }

    private static BigQueryNumeric? TryNumeric(string text)
    {
        try
        {
            return BigQueryNumeric.Parse(text.Trim());
        }
        catch (Exception ex) when (ex is FormatException or ArgumentException or OverflowException)
        {
            return null;
        }
    }

    private static BigQueryBigNumeric? TryBigNumeric(string text)
    {
        try
        {
            return BigQueryBigNumeric.Parse(text.Trim());
        }
        catch (Exception ex) when (ex is FormatException or ArgumentException or OverflowException)
        {
            return null;
        }
    }

    private static byte[]? FromHexOrBase64(string text)
    {
        var trimmed = text.Trim();
        if (trimmed.StartsWith("0x", StringComparison.OrdinalIgnoreCase))
        {
            trimmed = trimmed[2..];
        }

        try
        {
            return System.Convert.FromHexString(trimmed);
        }
        catch (FormatException)
        {
            try
            {
                return System.Convert.FromBase64String(text.Trim());
            }
            catch (FormatException)
            {
                return null;
            }
        }
    }
}
