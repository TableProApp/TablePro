using System.Globalization;
using MongoDB.Bson;
using TablePro.Drivers.MongoDb.Localization;

namespace TablePro.Drivers.MongoDb.Shell;

/// <summary>The value constructors mongosh offers, each turned into the BSON value it makes.</summary>
internal static class ShellConstructors
{
    private static readonly string[] DateFormats =
    [
        "yyyy-MM-dd'T'HH:mm:ss.FFFFFFFK",
        "yyyy-MM-dd'T'HH:mm:ssK",
        "yyyy-MM-dd'T'HH:mmK",
        "yyyy-MM-dd HH:mm:ss.FFFFFFFK",
        "yyyy-MM-dd HH:mm:ssK",
        "yyyy-MM-dd HH:mmK",
        "yyyy-MM-dd",
        "yyyyMMdd'T'HHmmssK",
    ];

    /// <summary>The value, or null when <paramref name="name"/> names no constructor.</summary>
    public static BsonValue? Build(string name, IReadOnlyList<BsonValue> args) => name switch
    {
        "ObjectId" or "ObjectID" => ObjectIdValue(args),
        "ISODate" or "Date" => DateValue(args),
        "NumberLong" or "Long" => new BsonInt64(WholeNumber(args, long.MinValue, long.MaxValue)),
        "NumberInt" or "Int32" => new BsonInt32((int)WholeNumber(args, int.MinValue, int.MaxValue)),
        "Double" => new BsonDouble(One(args).ToDouble()),
        "NumberDecimal" or "Decimal128" => DecimalValue(args),
        "UUID" => UuidValue(args),
        "BinData" => BinaryValue(args, hex: false),
        "HexData" => BinaryValue(args, hex: true),
        "Timestamp" => TimestampValue(args),
        "MinKey" => BsonMinKey.Value,
        "MaxKey" => BsonMaxKey.Value,
        "RegExp" => RegexValue(args),
        "Code" => new BsonJavaScript(Text(args, 0)),
        _ => null,
    };

    /// <summary>Reads a date as mongosh's ISODate does: text without a zone is UTC, a number is milliseconds since 1970.</summary>
    public static bool TryParseDate(string text, out DateTime utc)
    {
        const DateTimeStyles styles = DateTimeStyles.AssumeUniversal | DateTimeStyles.AdjustToUniversal | DateTimeStyles.AllowWhiteSpaces;
        if (DateTime.TryParseExact(text.Trim(), DateFormats, CultureInfo.InvariantCulture, styles, out utc))
        {
            return true;
        }

        return DateTime.TryParse(text, CultureInfo.InvariantCulture, styles, out utc);
    }

    private static BsonObjectId ObjectIdValue(IReadOnlyList<BsonValue> args)
    {
        if (args.Count == 0)
        {
            return new BsonObjectId(ObjectId.GenerateNewId());
        }

        var hex = Text(args, 0);
        return ObjectId.TryParse(hex, out var id)
            ? new BsonObjectId(id)
            : throw new FormatException(MongoStrings.Format("Mongo/NotObjectIdHex", Quoted(hex)));
    }

    private static BsonDateTime DateValue(IReadOnlyList<BsonValue> args)
    {
        if (args.Count == 0)
        {
            return new BsonDateTime(DateTime.UtcNow);
        }

        if (args.Count > 1)
        {
            throw new FormatException(MongoStrings.Get("Mongo/DateArgs"));
        }

        var arg = args[0];
        if (arg.IsNumeric)
        {
            return new BsonDateTime(arg.ToInt64());
        }

        if (arg.IsString && TryParseDate(arg.AsString, out var utc))
        {
            return new BsonDateTime(utc);
        }

        throw new FormatException(MongoStrings.Format("Mongo/NotADate", arg));
    }

    private static long WholeNumber(IReadOnlyList<BsonValue> args, long min, long max)
    {
        var arg = One(args);
        long value;
        if (arg.IsString)
        {
            if (!long.TryParse(arg.AsString.Trim(), NumberStyles.AllowLeadingSign, CultureInfo.InvariantCulture, out value))
            {
                throw new FormatException(MongoStrings.Format("Mongo/NotWholeNumber", Quoted(arg.AsString)));
            }
        }
        else if (arg.IsInt32 || arg.IsInt64)
        {
            value = arg.ToInt64();
        }
        else if (arg.IsDouble && Math.Floor(arg.AsDouble) == arg.AsDouble && Math.Abs(arg.AsDouble) < 9.2e18)
        {
            value = (long)arg.AsDouble;
        }
        else
        {
            throw new FormatException(MongoStrings.Format("Mongo/NotWholeNumber", arg));
        }

        return value < min || value > max ? throw new OverflowException(MongoStrings.Format("Mongo/OutOfRange", value)) : value;
    }

    private static BsonDecimal128 DecimalValue(IReadOnlyList<BsonValue> args)
    {
        var arg = One(args);
        var text = arg.IsString ? arg.AsString : arg.IsNumeric ? arg.ToString()! : throw new FormatException(MongoStrings.Format("Mongo/NotANumber", arg));
        return Decimal128.TryParse(text.Trim(), out var value) ? new BsonDecimal128(value) : throw new FormatException(MongoStrings.Format("Mongo/NotDecimal", Quoted(text)));
    }

    private static BsonBinaryData UuidValue(IReadOnlyList<BsonValue> args)
    {
        var guid = args.Count == 0 ? Guid.NewGuid() : Guid.TryParse(Text(args, 0), out var parsed) ? parsed : throw new FormatException(MongoStrings.Format("Mongo/NotUuid", Quoted(Text(args, 0))));
        return new BsonBinaryData(guid, GuidRepresentation.Standard);
    }

    private static BsonBinaryData BinaryValue(IReadOnlyList<BsonValue> args, bool hex)
    {
        if (args.Count != 2 || !args[0].IsNumeric || !args[1].IsString)
        {
            throw new FormatException(MongoStrings.Get("Mongo/BinaryArgs"));
        }

        var subType = args[0].ToInt32();
        if (subType is < 0 or > 255)
        {
            throw new OverflowException(MongoStrings.Format("Mongo/SubtypeOutOfRange", subType));
        }

        var bytes = hex ? Convert.FromHexString(args[1].AsString) : Convert.FromBase64String(args[1].AsString);
        return new BsonBinaryData(bytes, (BsonBinarySubType)subType);
    }

    private static BsonTimestamp TimestampValue(IReadOnlyList<BsonValue> args)
    {
        if (args.Count == 0)
        {
            return new BsonTimestamp(0);
        }

        if (args.Count == 1 && args[0] is BsonDocument document && document.TryGetValue("t", out var t) && document.TryGetValue("i", out var i))
        {
            return new BsonTimestamp(unchecked((int)(uint)t.ToInt64()), unchecked((int)(uint)i.ToInt64()));
        }

        if (args.Count == 2 && args[0].IsNumeric && args[1].IsNumeric)
        {
            return new BsonTimestamp(unchecked((int)(uint)args[0].ToInt64()), unchecked((int)(uint)args[1].ToInt64()));
        }

        throw new FormatException(MongoStrings.Get("Mongo/TimestampArgs"));
    }

    private static BsonRegularExpression RegexValue(IReadOnlyList<BsonValue> args)
    {
        if (args.Count is < 1 or > 2)
        {
            throw new FormatException(MongoStrings.Get("Mongo/RegexArgs"));
        }

        var flags = args.Count == 2 ? Text(args, 1) : string.Empty;
        return new BsonRegularExpression(Text(args, 0), new string(flags.Where(f => f is 'i' or 'm' or 's' or 'x' or 'u').Distinct().Order().ToArray()));
    }

    private static BsonValue One(IReadOnlyList<BsonValue> args) =>
        args.Count == 1 ? args[0] : throw new FormatException(MongoStrings.Get("Mongo/OneArgument"));

    private static string Text(IReadOnlyList<BsonValue> args, int index) =>
        index < args.Count && args[index].IsString ? args[index].AsString : throw new FormatException(MongoStrings.Get("Mongo/QuotedStringExpected"));

    // The text the user wrote, quoted as they would quote it in the shell.
    private static string Quoted(string text) => "\"" + text + "\"";
}
