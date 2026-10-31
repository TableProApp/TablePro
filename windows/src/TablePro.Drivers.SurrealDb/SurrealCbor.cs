using System.Buffers;
using System.Buffers.Binary;
using System.Globalization;
using System.Text;

namespace TablePro.Drivers.SurrealDb;

/// <summary>
/// The CBOR SurrealDB's RPC protocol speaks, where tags keep the types JSON flattens to text: a datetime, a decimal,
/// a uuid, a record id, NONE. Values decode to the CLR types the grid shows natively, or to the small records in
/// <see cref="SurrealValues"/> for the ones it has no type for.
/// </summary>
internal static class SurrealCbor
{
    // The tags SurrealDB documents for its CBOR format.
    public const ulong TagDatetimeString = 0;
    public const ulong TagNone = 6;
    public const ulong TagTable = 7;
    public const ulong TagRecordId = 8;
    public const ulong TagUuidString = 9;
    public const ulong TagDecimal = 10;
    public const ulong TagDatetimeCompact = 12;
    public const ulong TagDurationString = 13;
    public const ulong TagDurationCompact = 14;
    public const ulong TagUuidBinary = 37;
    public const ulong TagRange = 49;
    public const ulong TagBoundIncluded = 50;
    public const ulong TagBoundExcluded = 51;
    public const ulong TagGeometryPoint = 88;
    public const ulong TagGeometryCollection = 94;

    private const int MaxDepth = 256;

    public static object? Decode(ReadOnlySpan<byte> data)
    {
        var reader = new Reader(data);
        var value = reader.Read(0);
        return reader.Position == data.Length ? value : throw new FormatException("The CBOR answer has bytes after its value.");
    }

    /// <summary>The RPC request for one query: <c>{ id, method: "query", params: [sql] }</c>.</summary>
    public static byte[] QueryRequest(long id, string sql)
    {
        var buffer = new ArrayBufferWriter<byte>(sql.Length + 32);
        Head(buffer, 5, 3);
        Text(buffer, "id");
        Integer(buffer, id);
        Text(buffer, "method");
        Text(buffer, "query");
        Text(buffer, "params");
        Head(buffer, 4, 1);
        Text(buffer, sql);
        return buffer.WrittenSpan.ToArray();
    }

    private static void Text(ArrayBufferWriter<byte> buffer, string text)
    {
        var length = Encoding.UTF8.GetByteCount(text);
        Head(buffer, 3, (ulong)length);
        Encoding.UTF8.GetBytes(text, buffer.GetSpan(length));
        buffer.Advance(length);
    }

    private static void Integer(ArrayBufferWriter<byte> buffer, long value)
    {
        if (value >= 0)
        {
            Head(buffer, 0, (ulong)value);
        }
        else
        {
            Head(buffer, 1, (ulong)(-1 - value));
        }
    }

    private static void Head(ArrayBufferWriter<byte> buffer, byte major, ulong argument)
    {
        var prefix = (byte)(major << 5);
        var span = buffer.GetSpan(9);
        switch (argument)
        {
            case < 24:
                span[0] = (byte)(prefix | (byte)argument);
                buffer.Advance(1);
                break;
            case <= byte.MaxValue:
                span[0] = (byte)(prefix | 24);
                span[1] = (byte)argument;
                buffer.Advance(2);
                break;
            case <= ushort.MaxValue:
                span[0] = (byte)(prefix | 25);
                BinaryPrimitives.WriteUInt16BigEndian(span[1..], (ushort)argument);
                buffer.Advance(3);
                break;
            case <= uint.MaxValue:
                span[0] = (byte)(prefix | 26);
                BinaryPrimitives.WriteUInt32BigEndian(span[1..], (uint)argument);
                buffer.Advance(5);
                break;
            default:
                span[0] = (byte)(prefix | 27);
                BinaryPrimitives.WriteUInt64BigEndian(span[1..], argument);
                buffer.Advance(9);
                break;
        }
    }

    private ref struct Reader(ReadOnlySpan<byte> data)
    {
        private readonly ReadOnlySpan<byte> _data = data;

        public int Position { get; private set; }

        public object? Read(int depth)
        {
            if (depth > MaxDepth)
            {
                throw new FormatException("The CBOR answer nests too deeply.");
            }

            var initial = Byte();
            var major = initial >> 5;
            var info = (byte)(initial & 0x1F);
            switch (major)
            {
                case 0:
                {
                    var value = Argument(info);
                    return value <= long.MaxValue ? (object)(long)value : (decimal)value;
                }

                case 1:
                {
                    var value = Argument(info);
                    return value <= long.MaxValue ? (object)(-1 - (long)value) : -1m - value;
                }

                case 2:
                    return Bytes(Length(info)).ToArray();
                case 3:
                    return Encoding.UTF8.GetString(Bytes(Length(info)));
                case 4:
                {
                    var count = Length(info);
                    var items = new List<object?>(Math.Min(count, 1024));
                    for (var i = 0; i < count; i++)
                    {
                        items.Add(Read(depth + 1));
                    }

                    return items;
                }

                case 5:
                {
                    var count = Length(info);
                    var fields = new SurrealObject(Math.Min(count, 1024));
                    for (var i = 0; i < count; i++)
                    {
                        var key = Read(depth + 1);
                        fields.Add(key as string ?? Convert.ToString(key, CultureInfo.InvariantCulture) ?? string.Empty, Read(depth + 1));
                    }

                    return fields;
                }

                case 6:
                {
                    var tag = Argument(info);
                    return Tagged(tag, Read(depth + 1));
                }

                default:
                    return Simple(info);
            }
        }

        private object? Simple(byte info) => info switch
        {
            20 => false,
            21 => true,
            22 or 23 => null,
            25 => (double)BinaryPrimitives.ReadHalfBigEndian(Bytes(2)),
            26 => (double)BinaryPrimitives.ReadSingleBigEndian(Bytes(4)),
            27 => BinaryPrimitives.ReadDoubleBigEndian(Bytes(8)),
            _ => throw new FormatException(string.Create(CultureInfo.InvariantCulture, $"The CBOR answer has an unsupported simple value {info}.")),
        };

        private ulong Argument(byte info) => info switch
        {
            < 24 => info,
            24 => Byte(),
            25 => BinaryPrimitives.ReadUInt16BigEndian(Bytes(2)),
            26 => BinaryPrimitives.ReadUInt32BigEndian(Bytes(4)),
            27 => BinaryPrimitives.ReadUInt64BigEndian(Bytes(8)),

            // SurrealDB writes every length up front; an indefinite one means this is not its format.
            _ => throw new FormatException("The CBOR answer has an indefinite length, which SurrealDB does not send."),
        };

        private int Length(byte info)
        {
            var length = Argument(info);
            return length <= (ulong)(_data.Length - Position) ? (int)length : throw new FormatException("The CBOR answer ends early.");
        }

        private byte Byte() => Position < _data.Length ? _data[Position++] : throw new FormatException("The CBOR answer ends early.");

        private ReadOnlySpan<byte> Bytes(int count)
        {
            if (count > _data.Length - Position)
            {
                throw new FormatException("The CBOR answer ends early.");
            }

            var slice = _data.Slice(Position, count);
            Position += count;
            return slice;
        }
    }

    private static object? Tagged(ulong tag, object? inner) => tag switch
    {
        TagNone => null,
        TagTable => inner as string ?? Malformed(tag),
        TagRecordId when inner is List<object?> { Count: 2 } parts && parts[0] is string table => new SurrealRecord(table, parts[1]),
        TagUuidString when inner is string text && Guid.TryParse(text, out var uuid) => uuid,
        TagUuidBinary when inner is byte[] { Length: 16 } bytes => new Guid(bytes, bigEndian: true),
        TagUuidBinary when inner is string text && Guid.TryParse(text, out var uuid) => uuid,
        TagDecimal when inner is string text => SurrealValues.Decimal(text),
        TagDatetimeString when inner is string text => SurrealValues.Datetime(text),
        TagDatetimeCompact when inner is List<object?> parts => SurrealValues.Datetime(Part(parts, 0), Part(parts, 1)),
        TagDurationString when inner is string text => new SurrealDuration(text),
        TagDurationCompact when inner is List<object?> parts => new SurrealDuration(SurrealValues.FormatDuration(Part(parts, 0), Part(parts, 1))),
        TagRange when inner is List<object?> { Count: 2 } parts => new SurrealRange(parts[0] as SurrealBound, parts[1] as SurrealBound),
        TagBoundIncluded => new SurrealBound(inner, true),
        TagBoundExcluded => new SurrealBound(inner, false),
        >= TagGeometryPoint and <= TagGeometryCollection => new SurrealGeometry(tag, inner),
        TagRecordId or TagUuidString or TagUuidBinary or TagDecimal or TagDatetimeString or TagDatetimeCompact or TagDurationString or TagDurationCompact or TagRange => Malformed(tag),

        // A tag this client has no meaning for still carries a value worth showing.
        _ => inner,
    };

    private static long Part(List<object?> parts, int index) =>
        index < parts.Count && parts[index] is long value ? value : 0;

    private static string Malformed(ulong tag) =>
        throw new FormatException(string.Create(CultureInfo.InvariantCulture, $"The CBOR answer has a malformed value for tag {tag}."));
}
