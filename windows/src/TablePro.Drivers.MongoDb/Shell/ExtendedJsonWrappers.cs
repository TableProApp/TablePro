using System.Globalization;
using MongoDB.Bson;

namespace TablePro.Drivers.MongoDb.Shell;

/// <summary>
/// Turns the Extended JSON wrappers (canonical and relaxed) back into the values they name, so a JSON cell written by
/// <see cref="Documents.ExtendedJson"/> saves as the type it showed, and a filter pasted from Compass works in the
/// editor. A document that only looks like a wrapper, with other fields or the wrong value types, stays a document.
/// </summary>
internal static class ExtendedJsonWrappers
{
    public static bool TryUnwrap(BsonDocument document, out BsonValue value)
    {
        value = document;
        if (document.ElementCount is 0 or > 2 || !document.GetElement(0).Name.StartsWith('$'))
        {
            return false;
        }

        var first = document.GetElement(0);
        if (document.ElementCount == 2)
        {
            return first.Name == "$binary" && first.Value.IsString && document.GetElement(1) is { Name: "$type", Value.IsString: true } type
                && TryBinary(first.Value.AsString, type.Value.AsString, out value)
                || first.Name == "$code" && document.GetElement(1) is { Name: "$scope", Value: BsonDocument scope } && first.Value.IsString
                    && Set(new BsonJavaScriptWithScope(first.Value.AsString, scope), out value);
        }

        var inner = first.Value;
        switch (first.Name)
        {
            case "$oid" when inner.IsString && ObjectId.TryParse(inner.AsString, out var id):
                value = new BsonObjectId(id);
                return true;
            case "$date":
                return TryDate(inner, out value);
            case "$numberLong" when inner.IsString && long.TryParse(inner.AsString, NumberStyles.AllowLeadingSign, CultureInfo.InvariantCulture, out var l):
                value = new BsonInt64(l);
                return true;
            case "$numberInt" when inner.IsString && int.TryParse(inner.AsString, NumberStyles.AllowLeadingSign, CultureInfo.InvariantCulture, out var i):
                value = new BsonInt32(i);
                return true;
            case "$numberDouble" when inner.IsString:
                return TryDouble(inner.AsString, out value);
            case "$numberDecimal" when inner.IsString && Decimal128.TryParse(inner.AsString, out var d):
                value = new BsonDecimal128(d);
                return true;
            case "$binary" when inner is BsonDocument binary && binary.ElementCount == 2
                && binary.TryGetValue("base64", out var base64) && base64.IsString && binary.TryGetValue("subType", out var subType) && subType.IsString:
                return TryBinary(base64.AsString, subType.AsString, out value);
            case "$uuid" when inner.IsString && Guid.TryParse(inner.AsString, out var guid):
                value = new BsonBinaryData(guid, GuidRepresentation.Standard);
                return true;
            case "$regularExpression" when inner is BsonDocument regex && regex.ElementCount == 2
                && regex.TryGetValue("pattern", out var pattern) && pattern.IsString && regex.TryGetValue("options", out var options) && options.IsString:
                value = new BsonRegularExpression(pattern.AsString, options.AsString);
                return true;
            case "$timestamp" when inner is BsonDocument ts && ts.ElementCount == 2
                && ts.TryGetValue("t", out var t) && t.IsNumeric && ts.TryGetValue("i", out var inc) && inc.IsNumeric:
                value = new BsonTimestamp(unchecked((int)(uint)t.ToInt64()), unchecked((int)(uint)inc.ToInt64()));
                return true;
            case "$minKey" when inner.IsNumeric && inner.ToInt32() == 1:
                value = BsonMinKey.Value;
                return true;
            case "$maxKey" when inner.IsNumeric && inner.ToInt32() == 1:
                value = BsonMaxKey.Value;
                return true;
            case "$undefined" when inner.IsBoolean && inner.AsBoolean:
                value = BsonUndefined.Value;
                return true;
            case "$symbol" when inner.IsString:
                value = new BsonSymbol(inner.AsString);
                return true;
            case "$code" when inner.IsString:
                value = new BsonJavaScript(inner.AsString);
                return true;
            default:
                return false;
        }
    }

    private static bool Set(BsonValue result, out BsonValue value)
    {
        value = result;
        return true;
    }

    private static bool TryDate(BsonValue inner, out BsonValue value)
    {
        value = inner;
        if (inner.IsString && ShellConstructors.TryParseDate(inner.AsString, out var utc))
        {
            value = new BsonDateTime(utc);
            return true;
        }

        if (inner is BsonDocument { ElementCount: 1 } wrapped && wrapped.GetElement(0) is { Name: "$numberLong", Value.IsString: true } millis
            && long.TryParse(millis.Value.AsString, NumberStyles.AllowLeadingSign, CultureInfo.InvariantCulture, out var ms))
        {
            value = new BsonDateTime(ms);
            return true;
        }

        if (inner.IsInt32 || inner.IsInt64)
        {
            value = new BsonDateTime(inner.ToInt64());
            return true;
        }

        if (inner is BsonInt64 { } longMillis)
        {
            value = new BsonDateTime(longMillis.Value);
            return true;
        }

        return false;
    }

    private static bool TryDouble(string text, out BsonValue value)
    {
        value = BsonNull.Value;
        var parsed = text switch
        {
            "Infinity" => double.PositiveInfinity,
            "-Infinity" => double.NegativeInfinity,
            "NaN" => double.NaN,
            _ => double.TryParse(text, NumberStyles.Float, CultureInfo.InvariantCulture, out var d) ? d : (double?)null,
        };
        if (parsed is not { } number)
        {
            return false;
        }

        value = new BsonDouble(number);
        return true;
    }

    private static bool TryBinary(string base64, string subTypeHex, out BsonValue value)
    {
        value = BsonNull.Value;
        if (!byte.TryParse(subTypeHex, NumberStyles.HexNumber, CultureInfo.InvariantCulture, out var subType))
        {
            return false;
        }

        try
        {
            value = new BsonBinaryData(Convert.FromBase64String(base64), (BsonBinarySubType)subType);
            return true;
        }
        catch (FormatException)
        {
            return false;
        }
    }
}
