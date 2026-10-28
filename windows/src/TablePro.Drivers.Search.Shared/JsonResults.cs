using System.Globalization;
using System.Text;
using System.Text.Encodings.Web;
using System.Text.Json;
using System.Text.Json.Nodes;
using TablePro.Core.Results;

namespace TablePro.Drivers.Http;

/// <summary>Turns JSON values into grid cells: scalars keep their type, objects and arrays become their JSON text.</summary>
internal static class JsonCells
{
    public static readonly JsonWriterOptions Compact = new() { Encoder = JavaScriptEncoder.UnsafeRelaxedJsonEscaping };

    public static readonly JsonWriterOptions Indented = new() { Encoder = JavaScriptEncoder.UnsafeRelaxedJsonEscaping, Indented = true };

    public static object? ToCell(JsonElement value) => value.ValueKind switch
    {
        JsonValueKind.String => value.GetString(),
        JsonValueKind.Number => Number(value),
        JsonValueKind.True => true,
        JsonValueKind.False => false,
        JsonValueKind.Null or JsonValueKind.Undefined => null,
        _ => value.GetRawText(),
    };

    /// <summary>
    /// A number that fits a long stays one; a bigger integer such as an unsigned_long keeps every digit as a decimal,
    /// and only a fraction or exponent becomes a double.
    /// </summary>
    public static object Number(JsonElement value)
    {
        if (value.TryGetInt64(out var integer))
        {
            return integer;
        }

        var raw = value.GetRawText();
        if (raw.AsSpan().IndexOfAny(".eE") < 0 && decimal.TryParse(raw, NumberStyles.Integer, CultureInfo.InvariantCulture, out var big))
        {
            return big;
        }

        return value.GetDouble();
    }

    public static string Pretty(JsonElement value)
    {
        using var stream = new MemoryStream();
        using (var writer = new Utf8JsonWriter(stream, Indented))
        {
            value.WriteTo(writer);
        }

        return Encoding.UTF8.GetString(stream.GetBuffer(), 0, (int)stream.Length);
    }

    public static string Pretty(string json)
    {
        try
        {
            using var document = JsonDocument.Parse(json);
            return Pretty(document.RootElement);
        }
        catch (JsonException)
        {
            return json;
        }
    }

    public static string ToJson(JsonNode? node) => node is null ? "null" : node.ToJsonString(SerializerOptions);

    private static readonly JsonSerializerOptions SerializerOptions = new() { Encoder = JavaScriptEncoder.UnsafeRelaxedJsonEscaping };

    /// <summary>Visits each leaf of an object with its dotted path. Arrays are leaves: a list reads best as one cell.</summary>
    public static void Flatten(JsonElement value, string prefix, Action<string, JsonElement> leaf)
    {
        if (value.ValueKind != JsonValueKind.Object)
        {
            leaf(prefix, value);
            return;
        }

        var any = false;
        foreach (var property in value.EnumerateObject())
        {
            any = true;
            Flatten(property.Value, prefix.Length == 0 ? property.Name : string.Concat(prefix, ".", property.Name), leaf);
        }

        // An empty object is still a value the document holds, so it keeps a cell rather than vanishing.
        if (!any && prefix.Length > 0)
        {
            leaf(prefix, value);
        }
    }

    /// <summary>Typed grid input back into JSON for a write.</summary>
    public static JsonNode? ToNode(object? value) => value switch
    {
        null or DBNull => null,
        JsonNode node => node,
        string s => JsonValue.Create(s),
        bool b => JsonValue.Create(b),
        long l => JsonValue.Create(l),
        int i => JsonValue.Create(i),
        short sh => JsonValue.Create(sh),
        byte by => JsonValue.Create(by),
        decimal m => JsonValue.Create(m),
        double d => JsonValue.Create(d),
        float f => JsonValue.Create(f),
        ulong ul => JsonValue.Create(ul),
        uint ui => JsonValue.Create(ui),
        DateTime dt => JsonValue.Create(dt.ToString("O", CultureInfo.InvariantCulture)),
        DateTimeOffset dto => JsonValue.Create(dto.ToString("O", CultureInfo.InvariantCulture)),
        Guid g => JsonValue.Create(g.ToString()),
        _ => JsonValue.Create(Convert.ToString(value, CultureInfo.InvariantCulture)),
    };

    /// <summary>Text that is a JSON object or array, parsed; anything else null.</summary>
    public static JsonNode? TryParseStructure(string text)
    {
        var span = text.AsSpan().Trim();
        if (span.IsEmpty || (span[0] != '{' && span[0] != '['))
        {
            return null;
        }

        try
        {
            return JsonNode.Parse(text);
        }
        catch (JsonException)
        {
            return null;
        }
    }
}

/// <summary>
/// Builds a result from documents whose fields are not known in advance. Declared columns come first in their order;
/// fields found in the documents are added as they appear. A row is grown when a later document brings a new field.
/// </summary>
internal sealed class DocumentTable
{
    private readonly List<string> _names = [];
    private readonly Dictionary<string, int> _ordinals = new(StringComparer.Ordinal);
    private readonly List<(string DataType, Type ClrType)?> _declared = [];
    private readonly List<SeenKinds> _seen = [];
    private readonly List<object?[]> _rows = [];
    private object?[] _current = [];

    [Flags]
    private enum SeenKinds : byte
    {
        None = 0,
        Integer = 1,
        Real = 2,
        Boolean = 4,
        Other = 8,
    }

    public int RowCount => _rows.Count;

    public int ColumnCount => _names.Count;

    public void Declare(string name, string dataType, Type clrType)
    {
        var ordinal = Ordinal(name);
        _declared[ordinal] = (dataType, clrType);
    }

    public int Ordinal(string name)
    {
        if (_ordinals.TryGetValue(name, out var ordinal))
        {
            return ordinal;
        }

        ordinal = _names.Count;
        _names.Add(name);
        _ordinals[name] = ordinal;
        _declared.Add(null);
        _seen.Add(SeenKinds.None);
        return ordinal;
    }

    public void NewRow()
    {
        _current = new object?[Math.Max(_names.Count, 4)];
        _rows.Add(_current);
    }

    public void Set(string name, object? value)
    {
        var ordinal = Ordinal(name);
        if (ordinal >= _current.Length)
        {
            Array.Resize(ref _current, Math.Max(ordinal + 1, _current.Length * 2));
            _rows[^1] = _current;
        }

        _current[ordinal] = value;
        _seen[ordinal] |= value switch
        {
            null => SeenKinds.None,
            long or int => SeenKinds.Integer,
            double or decimal => SeenKinds.Real,
            bool => SeenKinds.Boolean,
            _ => SeenKinds.Other,
        };
    }

    public void Set(string name, JsonElement value) => Set(name, JsonCells.ToCell(value));

    /// <summary>Adds every leaf of a document to the current row under its dotted path.</summary>
    public void SetFlattened(JsonElement document, string prefix = "")
    {
        if (document.ValueKind != JsonValueKind.Object)
        {
            Set(prefix.Length == 0 ? "value" : prefix, document);
            return;
        }

        JsonCells.Flatten(document, prefix, (path, value) => Set(path, value));
    }

    /// <summary>Adds the document's top-level fields, keeping nested objects whole as JSON text.</summary>
    public void SetTopLevel(JsonElement document)
    {
        if (document.ValueKind != JsonValueKind.Object)
        {
            Set("value", document);
            return;
        }

        foreach (var property in document.EnumerateObject())
        {
            Set(property.Name, property.Value);
        }
    }

    public ResultSet Build(bool isTruncated = false)
    {
        var columns = new ResultColumn[_names.Count];
        for (var i = 0; i < columns.Length; i++)
        {
            var (dataType, clrType) = _declared[i] ?? Infer(_seen[i]);
            columns[i] = new ResultColumn(_names[i], dataType, clrType);
        }

        for (var r = 0; r < _rows.Count; r++)
        {
            if (_rows[r].Length != columns.Length)
            {
                var resized = _rows[r];
                Array.Resize(ref resized, columns.Length);
                _rows[r] = resized;
            }
        }

        return new ResultSet(columns, _rows, isTruncated);
    }

    private static (string DataType, Type ClrType) Infer(SeenKinds seen) => seen switch
    {
        SeenKinds.Integer => ("long", typeof(long)),
        SeenKinds.Real or (SeenKinds.Integer | SeenKinds.Real) => ("double", typeof(double)),
        SeenKinds.Boolean => ("boolean", typeof(bool)),
        _ => ("string", typeof(string)),
    };
}

/// <summary>Shapes for responses that are not lists of documents.</summary>
internal static class JsonTables
{
    /// <summary>Rows of (path, value) over the whole response, with array items indexed as <c>items[0].name</c>.</summary>
    public static ResultSet PathValue(JsonElement root, int rowLimit)
    {
        var rows = new List<object?[]>();
        var truncated = false;
        Walk(root, string.Empty);
        return new ResultSet([new ResultColumn("path", "string", typeof(string)), new ResultColumn("value", "json", typeof(string))], rows, truncated);

        void Walk(JsonElement value, string path)
        {
            if (truncated)
            {
                return;
            }

            switch (value.ValueKind)
            {
                case JsonValueKind.Object when HasAny(value):
                    foreach (var property in value.EnumerateObject())
                    {
                        Walk(property.Value, path.Length == 0 ? property.Name : string.Concat(path, ".", property.Name));
                    }

                    break;

                // A list of plain values reads best whole; only lists holding objects are opened up.
                case JsonValueKind.Array when value.EnumerateArray().Any(e => e.ValueKind is JsonValueKind.Object or JsonValueKind.Array):
                    var index = 0;
                    foreach (var item in value.EnumerateArray())
                    {
                        Walk(item, string.Create(CultureInfo.InvariantCulture, $"{path}[{index++}]"));
                    }

                    break;

                default:
                    if (rows.Count >= rowLimit)
                    {
                        truncated = true;
                        return;
                    }

                    // The value column holds mixed types, so every value is shown as text.
                    rows.Add([path, value.ValueKind switch
                    {
                        JsonValueKind.String => value.GetString(),
                        JsonValueKind.Null or JsonValueKind.Undefined => null,
                        _ => value.GetRawText(),
                    }]);
                    break;
            }
        }
    }

    /// <summary>The whole response as one cell, for a scalar or anything a table would only scatter.</summary>
    public static ResultSet Raw(string text, string column = "response") =>
        new([new ResultColumn(column, "json", typeof(string))], [[text]]);

    /// <summary>A list of objects as a table, or else the path and value of each leaf.</summary>
    public static ResultSet Auto(JsonElement root, int rowLimit)
    {
        if (root.ValueKind == JsonValueKind.Array && root.GetArrayLength() > 0 && root.EnumerateArray().All(e => e.ValueKind == JsonValueKind.Object))
        {
            var table = new DocumentTable();
            var truncated = false;
            foreach (var item in root.EnumerateArray())
            {
                if (table.RowCount >= rowLimit)
                {
                    truncated = true;
                    break;
                }

                table.NewRow();
                table.SetFlattened(item);
            }

            return table.Build(truncated);
        }

        if (root.ValueKind is JsonValueKind.Object or JsonValueKind.Array && HasAnyLeaf(root))
        {
            return PathValue(root, rowLimit);
        }

        return Raw(root.ValueKind == JsonValueKind.String ? root.GetString() ?? string.Empty : JsonCells.Pretty(root));
    }

    private static bool HasAny(JsonElement obj)
    {
        using var enumerator = obj.EnumerateObject();
        return enumerator.MoveNext();
    }

    private static bool HasAnyLeaf(JsonElement value) => value.ValueKind switch
    {
        JsonValueKind.Object => HasAny(value),
        JsonValueKind.Array => value.GetArrayLength() > 0,
        _ => true,
    };
}
