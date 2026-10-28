using System.Globalization;
using System.Text;
using System.Text.Json.Nodes;
using TablePro.Core.Editing;
using TablePro.Drivers.Http;

namespace TablePro.Drivers.Elasticsearch;

/// <summary>One REST call a save makes.</summary>
internal sealed record EsWrite(string Method, string Path, string? Body);

/// <summary>Turns grid changes into document writes: index, partial update and delete by <c>_id</c>.</summary>
internal static class EsWrites
{
    // Waits for the refresh so the grid's reload shows what was saved, without forcing one per write.
    public const string Refresh = "refresh=wait_for";

    public static EsWrite Single(string index, RowChange change, IReadOnlyDictionary<string, EsField> fields) => change switch
    {
        RowUpdate update => new EsWrite("POST", $"/{Segment(index)}/_update/{Segment(Id(update.Key))}?{Refresh}", JsonCells.ToJson(new JsonObject { ["doc"] = Document(update.Values, fields) })),
        RowInsert insert => InsertId(insert) is { } id
            ? new EsWrite("PUT", $"/{Segment(index)}/_create/{Segment(id)}?{Refresh}", JsonCells.ToJson(Document(insert.Values, fields, skipNulls: true)))
            : new EsWrite("POST", $"/{Segment(index)}/_doc?{Refresh}", JsonCells.ToJson(Document(insert.Values, fields, skipNulls: true))),
        RowDelete delete => new EsWrite("DELETE", $"/{Segment(index)}/_doc/{Segment(Id(delete.Key))}?{Refresh}", null),
        _ => throw new NotSupportedException(change.GetType().Name),
    };

    /// <summary>The newline-delimited body of a <c>_bulk</c> request, one action line and one source line per change.</summary>
    public static string Bulk(string index, IReadOnlyList<RowChange> changes, IReadOnlyDictionary<string, EsField> fields)
    {
        var sb = new StringBuilder();
        foreach (var change in changes)
        {
            switch (change)
            {
                case RowUpdate update:
                    Line(sb, new JsonObject { ["update"] = Target(index, Id(update.Key)) });
                    Line(sb, new JsonObject { ["doc"] = Document(update.Values, fields) });
                    break;
                case RowInsert insert:
                    Line(sb, new JsonObject { ["create"] = Target(index, InsertId(insert)) });
                    Line(sb, Document(insert.Values, fields, skipNulls: true));
                    break;
                case RowDelete delete:
                    Line(sb, new JsonObject { ["delete"] = Target(index, Id(delete.Key)) });
                    break;
                default:
                    throw new NotSupportedException(change.GetType().Name);
            }
        }

        return sb.ToString();
    }

    /// <summary>
    /// The document a change writes. Dotted columns become nested objects, since a partial update merges objects but
    /// would keep a dotted key as a separate field beside the object it names.
    /// </summary>
    public static JsonObject Document(IReadOnlyDictionary<string, object?> values, IReadOnlyDictionary<string, EsField> fields, bool skipNulls = false)
    {
        var document = new JsonObject();
        foreach (var (column, value) in values)
        {
            // A new row leaves untouched cells null; writing them would store explicit nulls for every mapped field.
            if (column is EsMapping.IdColumn or EsMapping.IndexColumn or EsMapping.ScoreColumn || (skipNulls && value is null))
            {
                continue;
            }

            fields.TryGetValue(column, out var field);
            var node = Value(value, field);
            var parts = column.Split('.');
            var target = document;
            for (var i = 0; i < parts.Length - 1; i++)
            {
                if (target[parts[i]] is not JsonObject child)
                {
                    child = new JsonObject();
                    target[parts[i]] = child;
                }

                target = child;
            }

            target[parts[^1]] = node;
        }

        return document;
    }

    /// <summary>
    /// Text the grid holds for a field becomes the JSON value the field takes. A JSON array is always parsed, since a
    /// list shows as its JSON; an object only for an object-typed field, so a keyword holding braces stays text.
    /// </summary>
    public static JsonNode? Value(object? value, EsField? field)
    {
        if (value is not string text)
        {
            return JsonCells.ToNode(value);
        }

        if (field is { IsNumeric: true })
        {
            if (long.TryParse(text, NumberStyles.Integer, CultureInfo.InvariantCulture, out var integer))
            {
                return integer;
            }

            if (double.TryParse(text, NumberStyles.Float, CultureInfo.InvariantCulture, out var real))
            {
                return real;
            }
        }

        if (field?.Type == "boolean" && bool.TryParse(text, out var flag))
        {
            return flag;
        }

        if (JsonCells.TryParseStructure(text) is { } structure && (structure is JsonArray || field is null || field.IsStructured))
        {
            return structure;
        }

        return text;
    }

    public static string Segment(string value) => Uri.EscapeDataString(value);

    private static string? InsertId(RowInsert insert) =>
        insert.Values.TryGetValue(EsMapping.IdColumn, out var id) && Convert.ToString(id, CultureInfo.InvariantCulture) is { Length: > 0 } text ? text : null;

    private static string Id(IReadOnlyDictionary<string, object?> key) =>
        key.TryGetValue(EsMapping.IdColumn, out var id) && Convert.ToString(id, CultureInfo.InvariantCulture) is { Length: > 0 } text
            ? text
            : throw new InvalidOperationException("The document's _id is unknown, so it cannot be addressed.");

    private static JsonObject Target(string index, string? id)
    {
        var target = new JsonObject { ["_index"] = index };
        if (id is not null)
        {
            target["_id"] = id;
        }

        return target;
    }

    private static void Line(StringBuilder sb, JsonNode node) => sb.Append(JsonCells.ToJson(node)).Append('\n');
}
