using System.Buffers.Binary;
using System.Globalization;
using System.Net;
using System.Numerics;
using System.Text;
using Cassandra;

namespace TablePro.Drivers.Cassandra;

/// <summary>A user-defined type value with its fields in declaration order.</summary>
public sealed record CqlUdtValue(string TypeName, IReadOnlyList<KeyValuePair<string, object?>> Fields);

/// <summary>A tuple value, decoded by <see cref="CqlValueDecoder"/> inside a user-defined type.</summary>
public sealed record CqlTupleValue(IReadOnlyList<object?> Elements);

/// <summary>A map value whose keys may be of any CQL type, kept in the order the server sent them.</summary>
public sealed record CqlMapValue(IReadOnlyList<KeyValuePair<object?, object?>> Entries);

/// <summary>Spells a column's CQL type from the result metadata, the way <c>DESCRIBE</c> writes it.</summary>
public static class CqlTypeNames
{
    public static string Format(ColumnTypeCode code, IColumnInfo? info) => code switch
    {
        ColumnTypeCode.Ascii => "ascii",
        ColumnTypeCode.Bigint => "bigint",
        ColumnTypeCode.Blob => "blob",
        ColumnTypeCode.Boolean => "boolean",
        ColumnTypeCode.Counter => "counter",
        ColumnTypeCode.Decimal => "decimal",
        ColumnTypeCode.Double => "double",
        ColumnTypeCode.Float => "float",
        ColumnTypeCode.Int => "int",
        ColumnTypeCode.Text or ColumnTypeCode.Varchar => "text",
        ColumnTypeCode.Timestamp => "timestamp",
        ColumnTypeCode.Uuid => "uuid",
        ColumnTypeCode.Varint => "varint",
        ColumnTypeCode.Timeuuid => "timeuuid",
        ColumnTypeCode.Inet => "inet",
        ColumnTypeCode.Date => "date",
        ColumnTypeCode.Time => "time",
        ColumnTypeCode.SmallInt => "smallint",
        ColumnTypeCode.TinyInt => "tinyint",
        ColumnTypeCode.Duration => "duration",
        ColumnTypeCode.List when info is ListColumnInfo list => $"list<{Format(list.ValueTypeCode, list.ValueTypeInfo)}>",
        ColumnTypeCode.Set when info is SetColumnInfo set => $"set<{Format(set.KeyTypeCode, set.KeyTypeInfo)}>",
        ColumnTypeCode.Map when info is MapColumnInfo map => $"map<{Format(map.KeyTypeCode, map.KeyTypeInfo)}, {Format(map.ValueTypeCode, map.ValueTypeInfo)}>",
        ColumnTypeCode.Tuple when info is TupleColumnInfo tuple => $"tuple<{string.Join(", ", tuple.Elements.Select(e => Format(e.TypeCode, e.TypeInfo)))}>",
        ColumnTypeCode.Udt when info is UdtColumnInfo udt => ShortUdtName(udt.Name),
        ColumnTypeCode.Custom when info is VectorColumnInfo vector =>
            string.Create(CultureInfo.InvariantCulture, $"vector<{Format(vector.ValueTypeCode, vector.ValueTypeInfo)}, {vector.Dimensions}>"),
        ColumnTypeCode.Custom when info is CustomColumnInfo custom => $"'{custom.CustomTypeName}'",
        _ => code.ToString().ToLowerInvariant(),
    };

    // The result metadata names a UDT as keyspace.type; the column type in system_schema is the bare name.
    private static string ShortUdtName(string name)
    {
        var dot = name.LastIndexOf('.');
        return dot < 0 ? name : name[(dot + 1)..];
    }
}

/// <summary>
/// Decodes CQL native protocol values (protocol v3 and later) for the parts of a row the driver hands over as bytes:
/// the fields of a user-defined type and everything nested in them.
/// </summary>
public static class CqlValueDecoder
{
    private static readonly DateOnly UnixEpochDate = new(1970, 1, 1);

    public static object? Decode(ReadOnlySpan<byte> bytes, ColumnTypeCode code, IColumnInfo? info)
    {
        switch (code)
        {
            case ColumnTypeCode.Ascii or ColumnTypeCode.Text or ColumnTypeCode.Varchar:
                return Encoding.UTF8.GetString(bytes);
            case ColumnTypeCode.Blob:
                return bytes.ToArray();
            case ColumnTypeCode.Custom when info is not VectorColumnInfo:
                return bytes.ToArray();
        }

        // A zero-length value of a fixed-width type is neither NULL nor a value; old clients could write it.
        if (bytes.IsEmpty)
        {
            return null;
        }

        return code switch
        {
            ColumnTypeCode.Bigint or ColumnTypeCode.Counter => BinaryPrimitives.ReadInt64BigEndian(bytes),
            ColumnTypeCode.Int => BinaryPrimitives.ReadInt32BigEndian(bytes),
            ColumnTypeCode.SmallInt => BinaryPrimitives.ReadInt16BigEndian(bytes),
            ColumnTypeCode.TinyInt => unchecked((sbyte)bytes[0]),
            ColumnTypeCode.Boolean => bytes[0] != 0,
            ColumnTypeCode.Double => BinaryPrimitives.ReadDoubleBigEndian(bytes),
            ColumnTypeCode.Float => BinaryPrimitives.ReadSingleBigEndian(bytes),
            ColumnTypeCode.Varint => new BigInteger(bytes, isUnsigned: false, isBigEndian: true),
            ColumnTypeCode.Decimal => DecodeDecimal(bytes),
            ColumnTypeCode.Uuid or ColumnTypeCode.Timeuuid => new Guid(bytes[..16], bigEndian: true),
            ColumnTypeCode.Inet => new IPAddress(bytes).ToString(),
            ColumnTypeCode.Timestamp => DecodeTimestamp(BinaryPrimitives.ReadInt64BigEndian(bytes)),
            ColumnTypeCode.Date => DecodeDate(BinaryPrimitives.ReadUInt32BigEndian(bytes)),
            ColumnTypeCode.Time => new TimeOnly(BinaryPrimitives.ReadInt64BigEndian(bytes) / 100),
            ColumnTypeCode.Duration => DecodeDuration(bytes),
            ColumnTypeCode.List when info is ListColumnInfo list => DecodeCollection(bytes, list.ValueTypeCode, list.ValueTypeInfo),
            ColumnTypeCode.Set when info is SetColumnInfo set => DecodeCollection(bytes, set.KeyTypeCode, set.KeyTypeInfo),
            ColumnTypeCode.Map when info is MapColumnInfo map => DecodeMap(bytes, map),
            ColumnTypeCode.Tuple when info is TupleColumnInfo tuple => DecodeTuple(bytes, tuple),
            ColumnTypeCode.Udt when info is UdtColumnInfo udt => DecodeUdt(bytes, udt),
            ColumnTypeCode.Custom when info is VectorColumnInfo vector => DecodeVector(bytes, vector),
            _ => bytes.ToArray(),
        };
    }

    public static CqlUdtValue DecodeUdt(ReadOnlySpan<byte> bytes, UdtColumnInfo udt)
    {
        var fields = new List<KeyValuePair<string, object?>>(udt.Fields.Count);
        var offset = 0;
        foreach (var field in udt.Fields)
        {
            // A UDT written before a field was added ends early; the missing fields read as NULL.
            fields.Add(new(field.Name, offset < bytes.Length ? ReadValue(bytes, ref offset, field.TypeCode, field.TypeInfo) : null));
        }

        return new CqlUdtValue(udt.Name, fields);
    }

    internal static string FormatDecimal(BigInteger unscaled, int scale)
    {
        if (scale <= 0)
        {
            return (unscaled * BigInteger.Pow(10, -scale)).ToString(CultureInfo.InvariantCulture);
        }

        var negative = unscaled.Sign < 0;
        var digits = BigInteger.Abs(unscaled).ToString(CultureInfo.InvariantCulture).PadLeft(scale + 1, '0');
        var text = string.Concat(digits.AsSpan(0, digits.Length - scale), ".", digits.AsSpan(digits.Length - scale));
        return negative ? "-" + text : text;
    }

    private static object? ReadValue(ReadOnlySpan<byte> bytes, ref int offset, ColumnTypeCode code, IColumnInfo? info)
    {
        var length = BinaryPrimitives.ReadInt32BigEndian(bytes[offset..]);
        offset += 4;
        if (length < 0)
        {
            return null;
        }

        var value = Decode(bytes.Slice(offset, length), code, info);
        offset += length;
        return value;
    }

    private static List<object?> DecodeCollection(ReadOnlySpan<byte> bytes, ColumnTypeCode code, IColumnInfo? info)
    {
        var count = BinaryPrimitives.ReadInt32BigEndian(bytes);
        var offset = 4;
        var items = new List<object?>(Math.Max(count, 0));
        for (var i = 0; i < count; i++)
        {
            items.Add(ReadValue(bytes, ref offset, code, info));
        }

        return items;
    }

    private static CqlMapValue DecodeMap(ReadOnlySpan<byte> bytes, MapColumnInfo map)
    {
        var count = BinaryPrimitives.ReadInt32BigEndian(bytes);
        var offset = 4;
        var entries = new List<KeyValuePair<object?, object?>>(Math.Max(count, 0));
        for (var i = 0; i < count; i++)
        {
            var key = ReadValue(bytes, ref offset, map.KeyTypeCode, map.KeyTypeInfo);
            var value = ReadValue(bytes, ref offset, map.ValueTypeCode, map.ValueTypeInfo);
            entries.Add(new(key, value));
        }

        return new CqlMapValue(entries);
    }

    private static CqlTupleValue DecodeTuple(ReadOnlySpan<byte> bytes, TupleColumnInfo tuple)
    {
        var elements = new List<object?>(tuple.Elements.Count);
        var offset = 0;
        foreach (var element in tuple.Elements)
        {
            elements.Add(offset < bytes.Length ? ReadValue(bytes, ref offset, element.TypeCode, element.TypeInfo) : null);
        }

        return new CqlTupleValue(elements);
    }

    // A vector of a fixed-width type packs its elements without lengths; a variable-width one prefixes each with a vint.
    private static List<object?> DecodeVector(ReadOnlySpan<byte> bytes, VectorColumnInfo vector)
    {
        var dimensions = vector.Dimensions ?? 0;
        var items = new List<object?>(dimensions);
        var width = FixedWidth(vector.ValueTypeCode);
        var offset = 0;
        for (var i = 0; i < dimensions && offset < bytes.Length; i++)
        {
            int length;
            if (width > 0)
            {
                length = width;
            }
            else
            {
                length = (int)ReadUnsignedVint(bytes, ref offset);
            }

            items.Add(Decode(bytes.Slice(offset, length), vector.ValueTypeCode, vector.ValueTypeInfo));
            offset += length;
        }

        return items;
    }

    private static int FixedWidth(ColumnTypeCode code) => code switch
    {
        ColumnTypeCode.Bigint or ColumnTypeCode.Double or ColumnTypeCode.Timestamp or ColumnTypeCode.Time or ColumnTypeCode.Counter => 8,
        ColumnTypeCode.Int or ColumnTypeCode.Float or ColumnTypeCode.Date => 4,
        ColumnTypeCode.SmallInt => 2,
        ColumnTypeCode.TinyInt or ColumnTypeCode.Boolean => 1,
        ColumnTypeCode.Uuid or ColumnTypeCode.Timeuuid => 16,
        _ => 0,
    };

    private static object DecodeDecimal(ReadOnlySpan<byte> bytes)
    {
        var scale = BinaryPrimitives.ReadInt32BigEndian(bytes);
        var unscaled = new BigInteger(bytes[4..], isUnsigned: false, isBigEndian: true);

        // System.Decimal holds 96 bits at a scale up to 28; anything wider stays exact as text.
        if (scale is >= 0 and <= 28 && BigInteger.Abs(unscaled) < (BigInteger.One << 96))
        {
            var magnitude = BigInteger.Abs(unscaled);
            var low = (int)(uint)(magnitude & uint.MaxValue);
            var mid = (int)(uint)((magnitude >> 32) & uint.MaxValue);
            var high = (int)(uint)((magnitude >> 64) & uint.MaxValue);
            return new decimal(low, mid, high, unscaled.Sign < 0, (byte)scale);
        }

        return FormatDecimal(unscaled, scale);
    }

    private static object DecodeTimestamp(long milliseconds)
    {
        const long min = -62135596800000L;
        const long max = 253402300799999L;
        return milliseconds is >= min and <= max
            ? DateTimeOffset.FromUnixTimeMilliseconds(milliseconds)
            : milliseconds.ToString(CultureInfo.InvariantCulture);
    }

    private static object DecodeDate(uint days)
    {
        // The protocol centers day 0 (1970-01-01) at 2^31 so dates before the epoch stay unsigned.
        var offset = (long)days - (1L << 31);
        var dayNumber = UnixEpochDate.DayNumber + offset;
        return dayNumber is >= 0 and <= 3652058 ? DateOnly.FromDayNumber((int)dayNumber) : offset.ToString(CultureInfo.InvariantCulture);
    }

    private static string DecodeDuration(ReadOnlySpan<byte> bytes)
    {
        var offset = 0;
        var months = (int)ZigZag(ReadUnsignedVint(bytes, ref offset));
        var days = (int)ZigZag(ReadUnsignedVint(bytes, ref offset));
        var nanoseconds = ZigZag(ReadUnsignedVint(bytes, ref offset));
        return new Duration(months, days, nanoseconds).ToString();
    }

    internal static ulong ReadUnsignedVint(ReadOnlySpan<byte> bytes, ref int offset)
    {
        var first = bytes[offset++];
        var extra = BitOperations.LeadingZeroCount((uint)(byte)~first) - 24;
        ulong value = (ulong)(first & (0xFF >> extra));
        for (var i = 0; i < extra; i++)
        {
            value = (value << 8) | bytes[offset++];
        }

        return value;
    }

    private static long ZigZag(ulong value) => (long)(value >> 1) ^ -(long)(value & 1);
}
