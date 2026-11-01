using System.Buffers.Binary;
using System.Collections.Immutable;

namespace TablePro.Core.Geometry;

/// <summary>
/// Reads WKB, PostGIS EWKB, MySQL's SRID-prefixed variant and the GeoPackage blob.
/// </summary>
/// <remarks>
/// Plain OGC WKB carries the type alone; ISO WKB adds 1000, 2000 or 3000 for Z, M and ZM; PostGIS EWKB sets high bits
/// instead (<c>0101000020</c> is SRID, <c>01010000A0</c> Z and SRID). All three are accepted because one PostGIS column
/// can hand over any of them. A geometry nested in a collection carries its own byte-order byte, so endianness is read
/// again per member, and <c>POINT EMPTY</c> is two NaN doubles rather than a zero-length body.
/// </remarks>
public static class WkbGeometryReader
{
    private const uint SridFlag = 0x2000_0000;
    private const uint ZFlag = 0x8000_0000;
    private const uint MFlag = 0x4000_0000;

    public static SpatialReading ReadHex(ReadOnlySpan<char> hex)
    {
        if (hex.IsEmpty || hex.Length % 2 != 0)
        {
            return SpatialReadFailure.NotGeometry;
        }

        // Rented rather than allocated: a page of hex cells would otherwise make one array each just to parse them.
        var length = hex.Length / 2;
        var rented = length <= 512 ? null : System.Buffers.ArrayPool<byte>.Shared.Rent(length);
        try
        {
            var bytes = rented is null ? stackalloc byte[length] : rented.AsSpan(0, length);
            if (Convert.FromHexString(hex, bytes, out _, out var written) != System.Buffers.OperationStatus.Done || written != length)
            {
                return SpatialReadFailure.NotGeometry;
            }

            return Read(bytes);
        }
        finally
        {
            if (rented is not null)
            {
                System.Buffers.ArrayPool<byte>.Shared.Return(rented);
            }
        }
    }

    public static SpatialReading Read(ReadOnlySpan<byte> bytes)
    {
        var cursor = new Cursor(bytes);
        var value = cursor.ReadGeometry(inheritedSrid: null);
        if (value is null)
        {
            return cursor.Failure ?? SpatialReadFailure.Malformed;
        }

        return cursor.IsAtEnd ? value : SpatialReadFailure.Malformed;
    }

    /// <summary>
    /// What MySQL and MariaDB hand back for a geometry column: a 4-byte little-endian SRID, then ordinary WKB. The SRID is
    /// kept because it is the only thing saying whether the coordinates are degrees, and both servers store a geographic
    /// system longitude first in these bytes even though <c>ST_AsText</c> prints latitude first for SRID 4326.
    /// </summary>
    public static SpatialReading ReadMySqlInternal(ReadOnlySpan<byte> bytes)
    {
        if (bytes.Length < 5)
        {
            return SpatialReadFailure.NotGeometry;
        }

        var srid = BinaryPrimitives.ReadUInt32LittleEndian(bytes);
        var reading = Read(bytes[4..]);
        return reading.Value is { } value
            ? new SpatialValue(srid == 0 ? null : unchecked((int)srid), value.Geometry)
            : reading;
    }

    /// <summary>
    /// A GeoPackage geometry blob, which is how SQLite files from GIS tools store shapes: <c>GP</c>, a version, flags
    /// naming the byte order and envelope size, the SRS id, the envelope, then standard WKB.
    /// </summary>
    public static SpatialReading ReadGeoPackage(ReadOnlySpan<byte> bytes)
    {
        if (!LooksLikeGeoPackage(bytes))
        {
            return SpatialReadFailure.NotGeometry;
        }

        var flags = bytes[3];
        var littleEndian = (flags & 0x01) != 0;
        var envelopeLength = ((flags >> 1) & 0x07) switch
        {
            0 => 0,
            1 => 32,
            2 or 3 => 48,
            4 => 64,
            _ => -1,
        };
        var bodyStart = 8 + envelopeLength;
        if (envelopeLength < 0 || bytes.Length < bodyStart)
        {
            return SpatialReadFailure.Malformed;
        }

        var srs = littleEndian ? BinaryPrimitives.ReadInt32LittleEndian(bytes[4..]) : BinaryPrimitives.ReadInt32BigEndian(bytes[4..]);

        // Bit 4 marks an empty geometry, which may carry no body at all.
        if ((flags & 0x10) != 0 && bytes.Length == bodyStart)
        {
            return new SpatialValue(srs <= 0 ? null : srs, EmptyGeometry.Instance);
        }

        var reading = Read(bytes[bodyStart..]);
        return reading.Value is { } value ? new SpatialValue(srs <= 0 ? null : srs, value.Geometry) : reading;
    }

    /// <summary>Bytes from a driver: GeoPackage by its magic, then WKB, then MySQL's SRID-prefixed form.</summary>
    public static SpatialReading ReadAny(ReadOnlySpan<byte> bytes)
    {
        if (LooksLikeGeoPackage(bytes))
        {
            return ReadGeoPackage(bytes);
        }

        var plain = Read(bytes);
        if (plain.Succeeded || plain.Failure.Kind == SpatialFailureKind.UnsupportedGeometryType)
        {
            return plain;
        }

        var mysql = ReadMySqlInternal(bytes);
        return mysql.Succeeded || mysql.Failure.Kind == SpatialFailureKind.UnsupportedGeometryType ? mysql : plain;
    }

    public static bool LooksLikeHex(ReadOnlySpan<char> text) =>
        text.Length >= 10 && text.Length % 2 == 0 && !text.ContainsAnyExcept(HexDigits);

    private static bool LooksLikeGeoPackage(ReadOnlySpan<byte> bytes) => bytes.Length >= 8 && bytes[0] == (byte)'G' && bytes[1] == (byte)'P';

    private static readonly System.Buffers.SearchValues<char> HexDigits = System.Buffers.SearchValues.Create("0123456789abcdefABCDEF");

    private static string? UnsupportedType(uint type) => type switch
    {
        8 => "CIRCULARSTRING",
        9 => "COMPOUNDCURVE",
        10 => "CURVEPOLYGON",
        11 => "MULTICURVE",
        12 => "MULTISURFACE",
        13 => "CURVE",
        14 => "SURFACE",
        15 => "POLYHEDRALSURFACE",
        16 => "TIN",
        17 => "TRIANGLE",
        _ => null,
    };

    private ref struct Cursor(ReadOnlySpan<byte> bytes)
    {
        private readonly ReadOnlySpan<byte> _bytes = bytes;
        private int _index;
        private int _depth;

        public SpatialReadFailure? Failure { get; private set; }

        public readonly bool IsAtEnd => _index >= _bytes.Length;

        public SpatialValue? ReadGeometry(int? inheritedSrid)
        {
            _depth++;
            try
            {
                if (_depth > SpatialLimits.MaximumNestingDepth)
                {
                    return Fail(SpatialReadFailure.Malformed);
                }

                if (ReadByteOrder() is not { } littleEndian || ReadUInt32(littleEndian) is not { } rawType)
                {
                    return null;
                }

                var type = rawType & 0x0FFF_FFFF;
                var hasZ = (rawType & ZFlag) != 0;
                var hasM = (rawType & MFlag) != 0;
                switch (type)
                {
                    case >= 3000:
                        type -= 3000;
                        hasZ = hasM = true;
                        break;
                    case >= 2000:
                        type -= 2000;
                        hasM = true;
                        break;
                    case >= 1000:
                        type -= 1000;
                        hasZ = true;
                        break;
                }

                var srid = inheritedSrid;
                if ((rawType & SridFlag) != 0)
                {
                    if (ReadUInt32(littleEndian) is not { } raw)
                    {
                        return null;
                    }

                    srid = raw == 0 ? null : unchecked((int)raw);
                }

                if (UnsupportedType(type) is { } name)
                {
                    return Fail(SpatialReadFailure.Unsupported(name));
                }

                var ordinates = 2 + (hasZ ? 1 : 0) + (hasM ? 1 : 0);
                return ReadBody(type, littleEndian, ordinates, srid) is { } geometry ? new SpatialValue(srid, geometry) : null;
            }
            finally
            {
                _depth--;
            }
        }

        private SpatialGeometry? ReadBody(uint type, bool littleEndian, int ordinates, int? srid)
        {
            switch (type)
            {
                case 1:
                    if (ReadPoint(littleEndian, ordinates) is not { } point)
                    {
                        return null;
                    }

                    // A NaN pair is how every producer writes POINT EMPTY; the format has no zero-length point body.
                    return double.IsNaN(point.X) || double.IsNaN(point.Y) ? EmptyGeometry.Instance : new PointGeometry(point);
                case 2:
                    return ReadRun(littleEndian, ordinates) is { } line ? new LineStringGeometry(line) : null;
                case 3:
                    return ReadRings(littleEndian, ordinates) is { } rings ? new PolygonGeometry(rings) : null;
                case 4:
                {
                    if (ReadChildren(littleEndian, srid) is not { } children)
                    {
                        return null;
                    }

                    var points = ImmutableArray.CreateBuilder<SpatialPoint>(children.Length);
                    foreach (var child in children)
                    {
                        switch (child)
                        {
                            case PointGeometry p:
                                points.Add(p.Point);
                                break;
                            case EmptyGeometry:
                                break;
                            default:
                                return Fail<SpatialGeometry>(SpatialReadFailure.Malformed);
                        }
                    }

                    return new MultiPointGeometry(points.DrainToImmutable());
                }

                case 5:
                {
                    if (ReadChildren(littleEndian, srid) is not { } children)
                    {
                        return null;
                    }

                    var lines = ImmutableArray.CreateBuilder<ImmutableArray<SpatialPoint>>(children.Length);
                    foreach (var child in children)
                    {
                        switch (child)
                        {
                            case LineStringGeometry l:
                                lines.Add(l.Points);
                                break;
                            case EmptyGeometry:
                                lines.Add([]);
                                break;
                            default:
                                return Fail<SpatialGeometry>(SpatialReadFailure.Malformed);
                        }
                    }

                    return new MultiLineStringGeometry(lines.MoveToImmutable());
                }

                case 6:
                {
                    if (ReadChildren(littleEndian, srid) is not { } children)
                    {
                        return null;
                    }

                    var polygons = ImmutableArray.CreateBuilder<ImmutableArray<ImmutableArray<SpatialPoint>>>(children.Length);
                    foreach (var child in children)
                    {
                        switch (child)
                        {
                            case PolygonGeometry p:
                                polygons.Add(p.Rings);
                                break;
                            case EmptyGeometry:
                                polygons.Add([]);
                                break;
                            default:
                                return Fail<SpatialGeometry>(SpatialReadFailure.Malformed);
                        }
                    }

                    return new MultiPolygonGeometry(polygons.MoveToImmutable());
                }

                case 7:
                    return ReadChildren(littleEndian, srid) is { } members ? new GeometryCollection(members) : null;
                default:
                    return Fail<SpatialGeometry>(SpatialReadFailure.Malformed);
            }
        }

        private ImmutableArray<SpatialGeometry>? ReadChildren(bool littleEndian, int? srid)
        {
            if (ReadCount(littleEndian, minimumBytesEach: 5) is not { } count)
            {
                return null;
            }

            var children = ImmutableArray.CreateBuilder<SpatialGeometry>(count);
            for (var i = 0; i < count; i++)
            {
                if (ReadGeometry(srid) is not { } child)
                {
                    return null;
                }

                children.Add(child.Geometry);
            }

            return children.MoveToImmutable();
        }

        private ImmutableArray<ImmutableArray<SpatialPoint>>? ReadRings(bool littleEndian, int ordinates)
        {
            if (ReadCount(littleEndian, minimumBytesEach: 4) is not { } count)
            {
                return null;
            }

            var rings = ImmutableArray.CreateBuilder<ImmutableArray<SpatialPoint>>(count);
            for (var i = 0; i < count; i++)
            {
                if (ReadRun(littleEndian, ordinates) is not { } ring)
                {
                    return null;
                }

                rings.Add(ring);
            }

            return rings.MoveToImmutable();
        }

        private ImmutableArray<SpatialPoint>? ReadRun(bool littleEndian, int ordinates)
        {
            // A corrupt buffer can declare a huge count; checking it against the bytes left refuses it before any
            // capacity is reserved for it.
            if (ReadCount(littleEndian, minimumBytesEach: ordinates * 8) is not { } count)
            {
                return null;
            }

            var points = new SpatialPoint[count];
            for (var i = 0; i < count; i++)
            {
                if (ReadPoint(littleEndian, ordinates) is not { } point)
                {
                    return null;
                }

                points[i] = point;
            }

            return System.Runtime.InteropServices.ImmutableCollectionsMarshal.AsImmutableArray(points);
        }

        private int? ReadCount(bool littleEndian, int minimumBytesEach)
        {
            if (ReadUInt32(littleEndian) is not { } count)
            {
                return null;
            }

            if (count > (ulong)(_bytes.Length - _index) / (ulong)minimumBytesEach)
            {
                Failure = SpatialReadFailure.Malformed;
                return null;
            }

            return (int)count;
        }

        private SpatialPoint? ReadPoint(bool littleEndian, int ordinates)
        {
            if (_bytes.Length - _index < ordinates * 8)
            {
                Failure = SpatialReadFailure.Malformed;
                return null;
            }

            var x = ReadDouble(littleEndian);
            var y = ReadDouble(littleEndian);
            _index += (ordinates - 2) * 8;
            return new SpatialPoint(x, y);
        }

        private bool? ReadByteOrder()
        {
            if (_index >= _bytes.Length)
            {
                Failure = SpatialReadFailure.Malformed;
                return null;
            }

            switch (_bytes[_index++])
            {
                case 0:
                    return false;
                case 1:
                    return true;
                default:
                    Failure = SpatialReadFailure.NotGeometry;
                    return null;
            }
        }

        private uint? ReadUInt32(bool littleEndian)
        {
            if (_bytes.Length - _index < 4)
            {
                Failure = SpatialReadFailure.Malformed;
                return null;
            }

            var slice = _bytes.Slice(_index, 4);
            _index += 4;
            return littleEndian ? BinaryPrimitives.ReadUInt32LittleEndian(slice) : BinaryPrimitives.ReadUInt32BigEndian(slice);
        }

        private double ReadDouble(bool littleEndian)
        {
            var slice = _bytes.Slice(_index, 8);
            _index += 8;
            return littleEndian ? BinaryPrimitives.ReadDoubleLittleEndian(slice) : BinaryPrimitives.ReadDoubleBigEndian(slice);
        }

        private SpatialValue? Fail(SpatialReadFailure failure)
        {
            Failure = failure;
            return null;
        }

        private T? Fail<T>(SpatialReadFailure failure)
            where T : class
        {
            Failure = failure;
            return null;
        }
    }
}
