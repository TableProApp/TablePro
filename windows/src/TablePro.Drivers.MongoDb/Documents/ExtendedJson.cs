using System.Globalization;
using System.Text;
using MongoDB.Bson;

namespace TablePro.Drivers.MongoDb.Documents;

/// <summary>How <see cref="ExtendedJson"/> spells the BSON types JSON has no literal for.</summary>
internal enum JsonFlavor
{
    /// <summary>Relaxed Extended JSON, except that a long keeps its <c>$numberLong</c> wrapper so an edit cannot narrow it.</summary>
    Relaxed,

    /// <summary>mongosh constructors such as <c>ObjectId("...")</c> and <c>ISODate("...")</c>, for scripts a user runs.</summary>
    Shell,
}

/// <summary>
/// Writes BSON as text. The driver's own JSON writer cannot be told to keep longs wrapped in relaxed mode, and a JSON
/// cell that read back an <c>int</c> where a <c>long</c> was stored would change the document's type on save.
/// </summary>
internal static class ExtendedJson
{
    private const long MaxIsoMillis = 253_402_300_799_999;
    private const char LineSeparator = '\u2028';
    private const char ParagraphSeparator = '\u2029';

    public static string Write(BsonValue value, JsonFlavor flavor = JsonFlavor.Relaxed, bool indented = false)
    {
        var sb = new StringBuilder();
        Append(sb, value, flavor, indented ? 0 : -1);
        return sb.ToString();
    }

    public static void Append(StringBuilder sb, BsonValue value, JsonFlavor flavor, int indent)
    {
        switch (value.BsonType)
        {
            case BsonType.Document:
                AppendDocument(sb, value.AsBsonDocument, flavor, indent);
                break;
            case BsonType.Array:
                AppendArray(sb, value.AsBsonArray, flavor, indent);
                break;
            case BsonType.String:
                AppendString(sb, value.AsString);
                break;
            case BsonType.Int32:
                sb.Append(value.AsInt32.ToString(CultureInfo.InvariantCulture));
                break;
            case BsonType.Int64:
                var text = value.AsInt64.ToString(CultureInfo.InvariantCulture);
                if (flavor == JsonFlavor.Shell)
                {
                    sb.Append("NumberLong(\"").Append(text).Append("\")");
                }
                else
                {
                    sb.Append("{\"$numberLong\": \"").Append(text).Append("\"}");
                }

                break;
            case BsonType.Double:
                AppendDouble(sb, value.AsDouble, flavor);
                break;
            case BsonType.Decimal128:
                var decimalText = value.AsDecimal128.ToString();
                sb.Append(flavor == JsonFlavor.Shell ? "NumberDecimal(\"" : "{\"$numberDecimal\": \"").Append(decimalText).Append(flavor == JsonFlavor.Shell ? "\")" : "\"}");
                break;
            case BsonType.Boolean:
                sb.Append(value.AsBoolean ? "true" : "false");
                break;
            case BsonType.Null:
                sb.Append("null");
                break;
            case BsonType.ObjectId:
                var hex = value.AsObjectId.ToString();
                sb.Append(flavor == JsonFlavor.Shell ? "ObjectId(\"" : "{\"$oid\": \"").Append(hex).Append(flavor == JsonFlavor.Shell ? "\")" : "\"}");
                break;
            case BsonType.DateTime:
                AppendDate(sb, value.AsBsonDateTime.MillisecondsSinceEpoch, flavor);
                break;
            case BsonType.Binary:
                AppendBinary(sb, value.AsBsonBinaryData, flavor);
                break;
            case BsonType.RegularExpression:
                var regex = value.AsBsonRegularExpression;
                if (flavor == JsonFlavor.Shell && !regex.Pattern.Contains('/', StringComparison.Ordinal) && !regex.Pattern.Contains('\n', StringComparison.Ordinal))
                {
                    sb.Append('/').Append(regex.Pattern).Append('/').Append(regex.Options);
                }
                else
                {
                    sb.Append("{\"$regularExpression\": {\"pattern\": ");
                    AppendString(sb, regex.Pattern);
                    sb.Append(", \"options\": ");
                    AppendString(sb, regex.Options);
                    sb.Append("}}");
                }

                break;
            case BsonType.Timestamp:
                var ts = value.AsBsonTimestamp;
                sb.Append(flavor == JsonFlavor.Shell ? "Timestamp({\"t\": " : "{\"$timestamp\": {\"t\": ")
                    .Append(((uint)ts.Timestamp).ToString(CultureInfo.InvariantCulture))
                    .Append(", \"i\": ")
                    .Append(((uint)ts.Increment).ToString(CultureInfo.InvariantCulture))
                    .Append(flavor == JsonFlavor.Shell ? "})" : "}}");
                break;
            case BsonType.MinKey:
                sb.Append(flavor == JsonFlavor.Shell ? "MinKey()" : "{\"$minKey\": 1}");
                break;
            case BsonType.MaxKey:
                sb.Append(flavor == JsonFlavor.Shell ? "MaxKey()" : "{\"$maxKey\": 1}");
                break;
            case BsonType.Undefined:
                sb.Append("{\"$undefined\": true}");
                break;
            case BsonType.Symbol:
                sb.Append("{\"$symbol\": ");
                AppendString(sb, value.AsBsonSymbol.Name);
                sb.Append('}');
                break;
            case BsonType.JavaScript:
                sb.Append("{\"$code\": ");
                AppendString(sb, value.AsBsonJavaScript.Code);
                sb.Append('}');
                break;
            case BsonType.JavaScriptWithScope:
                var code = value.AsBsonJavaScriptWithScope;
                sb.Append("{\"$code\": ");
                AppendString(sb, code.Code);
                sb.Append(", \"$scope\": ");
                AppendDocument(sb, code.Scope, flavor, -1);
                sb.Append('}');
                break;
            default:
                // Only DBPointer is left, deprecated since MongoDB 1.x; its string form still names what it holds.
                AppendString(sb, value.ToString() ?? string.Empty);
                break;
        }
    }

    public static void AppendString(StringBuilder sb, string value)
    {
        sb.Append('"');
        foreach (var c in value)
        {
            switch (c)
            {
                case '"':
                    sb.Append("\\\"");
                    break;
                case '\\':
                    sb.Append("\\\\");
                    break;
                case '\n':
                    sb.Append("\\n");
                    break;
                case '\r':
                    sb.Append("\\r");
                    break;
                case '\t':
                    sb.Append("\\t");
                    break;
                case '\b':
                    sb.Append("\\b");
                    break;
                case '\f':
                    sb.Append("\\f");
                    break;

                // U+2028 and U+2029 end a line in JavaScript, which would split a statement the editor runs.
                case < ' ' or LineSeparator or ParagraphSeparator:
                    sb.Append("\\u").Append(((int)c).ToString("x4", CultureInfo.InvariantCulture));
                    break;
                default:
                    sb.Append(c);
                    break;
            }
        }

        sb.Append('"');
    }

    private static void AppendDocument(StringBuilder sb, BsonDocument document, JsonFlavor flavor, int indent)
    {
        if (document.ElementCount == 0)
        {
            sb.Append("{}");
            return;
        }

        sb.Append('{');
        var first = true;
        foreach (var element in document)
        {
            if (!first)
            {
                sb.Append(',');
                if (indent < 0)
                {
                    sb.Append(' ');
                }
            }

            if (indent >= 0)
            {
                NewLine(sb, indent + 1);
            }

            AppendString(sb, element.Name);
            sb.Append(": ");
            Append(sb, element.Value, flavor, indent < 0 ? -1 : indent + 1);
            first = false;
        }

        NewLine(sb, indent);
        sb.Append('}');
    }

    private static void AppendArray(StringBuilder sb, BsonArray array, JsonFlavor flavor, int indent)
    {
        if (array.Count == 0)
        {
            sb.Append("[]");
            return;
        }

        sb.Append('[');
        for (var i = 0; i < array.Count; i++)
        {
            if (i > 0)
            {
                sb.Append(',');
                if (indent < 0)
                {
                    sb.Append(' ');
                }
            }

            if (indent >= 0)
            {
                NewLine(sb, indent + 1);
            }

            Append(sb, array[i], flavor, indent < 0 ? -1 : indent + 1);
        }

        NewLine(sb, indent);
        sb.Append(']');
    }

    private static void NewLine(StringBuilder sb, int indent)
    {
        if (indent >= 0)
        {
            sb.Append('\n').Append(' ', indent * 2);
        }
    }

    private static void AppendDouble(StringBuilder sb, double value, JsonFlavor flavor)
    {
        if (double.IsNaN(value) || double.IsInfinity(value))
        {
            var name = double.IsNaN(value) ? "NaN" : value > 0 ? "Infinity" : "-Infinity";
            sb.Append(flavor == JsonFlavor.Shell ? name : $"{{\"$numberDouble\": \"{name}\"}}");
            return;
        }

        var text = value.ToString("R", CultureInfo.InvariantCulture);

        // A whole double written without a point would read back as an int.
        if (text.AsSpan().IndexOfAny('.', 'E', 'e') < 0)
        {
            text += ".0";
        }

        sb.Append(text);
    }

    private static void AppendDate(StringBuilder sb, long millis, JsonFlavor flavor)
    {
        var millisText = millis.ToString(CultureInfo.InvariantCulture);
        if (millis is >= 0 and <= MaxIsoMillis)
        {
            var iso = DateTimeOffset.FromUnixTimeMilliseconds(millis).UtcDateTime.ToString("yyyy-MM-dd'T'HH:mm:ss.fff'Z'", CultureInfo.InvariantCulture);
            sb.Append(flavor == JsonFlavor.Shell ? "ISODate(\"" : "{\"$date\": \"").Append(iso).Append(flavor == JsonFlavor.Shell ? "\")" : "\"}");
        }
        else if (flavor == JsonFlavor.Shell)
        {
            sb.Append("new Date(").Append(millisText).Append(')');
        }
        else
        {
            sb.Append("{\"$date\": {\"$numberLong\": \"").Append(millisText).Append("\"}}");
        }
    }

    private static void AppendBinary(StringBuilder sb, BsonBinaryData binary, JsonFlavor flavor)
    {
        if (binary.SubType == BsonBinarySubType.UuidStandard && binary.Bytes.Length == 16)
        {
            var uuid = new Guid(binary.Bytes, bigEndian: true).ToString();
            sb.Append(flavor == JsonFlavor.Shell ? "UUID(\"" : "{\"$uuid\": \"").Append(uuid).Append(flavor == JsonFlavor.Shell ? "\")" : "\"}");
            return;
        }

        var base64 = Convert.ToBase64String(binary.Bytes);
        var subType = ((byte)binary.SubType).ToString("x2", CultureInfo.InvariantCulture);
        if (flavor == JsonFlavor.Shell)
        {
            sb.Append("BinData(").Append(((byte)binary.SubType).ToString(CultureInfo.InvariantCulture)).Append(", \"").Append(base64).Append("\")");
        }
        else
        {
            sb.Append("{\"$binary\": {\"base64\": \"").Append(base64).Append("\", \"subType\": \"").Append(subType).Append("\"}}");
        }
    }
}
