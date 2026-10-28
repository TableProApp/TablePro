using System.Globalization;
using MongoDB.Bson;
using TablePro.Core.Results;
using TablePro.Drivers.MongoDb.Shell;

namespace TablePro.Drivers.MongoDb.Documents;

/// <summary>
/// Moves values between BSON and grid cells. A cell holds the column's native type, or relaxed Extended JSON text for
/// a JSON column and for a value whose type the column was not inferred with, so nothing is lost on the way back.
/// </summary>
internal static class DocumentCells
{
    public static object?[] Flatten(BsonDocument document, IReadOnlyList<FieldColumn> columns)
    {
        var row = new object?[columns.Count];
        for (var i = 0; i < columns.Count; i++)
        {
            row[i] = document.TryGetValue(columns[i].Name, out var value) ? ToCell(value, columns[i]) : null;
        }

        return row;
    }

    public static object? ToCell(BsonValue value, FieldColumn column)
    {
        if (value.IsBsonNull)
        {
            return null;
        }

        object? native = column.Kind switch
        {
            FieldKind.Int when value.IsInt32 => value.AsInt32,
            FieldKind.Long when value.IsInt32 || value.IsInt64 => value.ToInt64(),
            FieldKind.Double when value.IsInt32 || value.IsInt64 || value.IsDouble => value.ToDouble(),
            FieldKind.Decimal when value.IsNumeric => ToDecimal(value),
            FieldKind.String when value.IsString => value.AsString,
            FieldKind.Bool when value.IsBoolean => value.AsBoolean,
            FieldKind.Date when value.IsValidDateTime => value.ToUniversalTime(),
            FieldKind.ObjectId when value.IsObjectId => value.AsObjectId.ToString(),
            _ => null,
        };

        return native ?? ExtendedJson.Write(value);
    }

    /// <summary>
    /// The BSON for a cell value about to be saved or matched. <paramref name="column"/> is null for a field the
    /// structure does not know, whose value is then taken as the type it arrived in.
    /// </summary>
    public static BsonValue FromCell(object? value, FieldColumn? column)
    {
        if (value is null or DBNull)
        {
            return BsonNull.Value;
        }

        if (value is string text && column is not null)
        {
            return column.Kind switch
            {
                FieldKind.Json => ParseJson(text, column.Name),
                FieldKind.ObjectId when ObjectId.TryParse(text, out var id) => new BsonObjectId(id),
                FieldKind.Date when ShellConstructors.TryParseDate(text, out var utc) => new BsonDateTime(utc),
                FieldKind.String => new BsonString(text),

                // A value of another type than the column's was shown as Extended JSON, and goes back as what it names.
                _ when LooksLikeJson(text) => TryParseJson(text) ?? new BsonString(text),
                _ => new BsonString(text),
            };
        }

        return value switch
        {
            string s => new BsonString(s),
            bool b => BsonBoolean.Create(b),
            int i => new BsonInt32(i),
            long l => new BsonInt64(l),
            short s => new BsonInt32(s),
            byte b => new BsonInt32(b),
            sbyte sb => new BsonInt32(sb),
            ushort us => new BsonInt32(us),
            uint ui => new BsonInt64(ui),
            ulong ul when ul <= long.MaxValue => new BsonInt64((long)ul),
            double d => new BsonDouble(d),
            float f => new BsonDouble(f),
            decimal m => column?.Kind is FieldKind.Double ? new BsonDouble((double)m) : new BsonDecimal128(m),
            DateTime dt => new BsonDateTime(dt.Kind == DateTimeKind.Unspecified ? DateTime.SpecifyKind(dt, DateTimeKind.Utc) : dt.ToUniversalTime()),
            DateTimeOffset dto => new BsonDateTime(dto.UtcDateTime),
            DateOnly d => new BsonDateTime(d.ToDateTime(TimeOnly.MinValue, DateTimeKind.Utc)),
            Guid g => new BsonBinaryData(g, GuidRepresentation.Standard),
            byte[] bytes => new BsonBinaryData(bytes),
            ObjectId oid => new BsonObjectId(oid),
            BsonValue bson => bson,
            _ => new BsonString(Convert.ToString(value, CultureInfo.InvariantCulture) ?? string.Empty),
        };
    }

    public static ResultColumn[] ResultColumns(IReadOnlyList<FieldColumn> columns)
    {
        var result = new ResultColumn[columns.Count];
        for (var i = 0; i < columns.Count; i++)
        {
            result[i] = columns[i].ToResultColumn();
        }

        return result;
    }

    private static BsonValue ParseJson(string text, string column)
    {
        try
        {
            return ShellParser.ParseValue(text);
        }
        catch (ShellSyntaxException ex)
        {
            throw new FormatException($"{column} holds JSON, and its new value does not read as JSON: {ex.Reason} at column {ex.Column}.", ex);
        }
    }

    private static bool LooksLikeJson(string text)
    {
        var trimmed = text.AsSpan().TrimStart();
        return !trimmed.IsEmpty && trimmed[0] is '{' or '[' or '"';
    }

    private static BsonValue? TryParseJson(string text)
    {
        try
        {
            return ShellParser.ParseValue(text);
        }
        catch (ShellSyntaxException)
        {
            return null;
        }
    }

    private static object ToDecimal(BsonValue value)
    {
        if (value.IsDouble)
        {
            return TryDecimal(value.AsDouble) is { } fits ? fits : ExtendedJson.Write(value);
        }

        if (!value.IsDecimal128)
        {
            return (decimal)value.ToInt64();
        }

        var d = value.AsDecimal128;
        if (Decimal128.IsNaN(d) || Decimal128.IsInfinity(d))
        {
            return ExtendedJson.Write(value);
        }

        try
        {
            return Decimal128.ToDecimal(d);
        }
        catch (OverflowException)
        {
            return ExtendedJson.Write(value);
        }
    }

    private static decimal? TryDecimal(double value)
    {
        if (double.IsNaN(value) || double.IsInfinity(value) || Math.Abs(value) > 7.9e28)
        {
            return null;
        }

        return (decimal)value;
    }
}
