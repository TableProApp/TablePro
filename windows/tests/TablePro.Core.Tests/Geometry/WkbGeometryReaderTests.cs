using TablePro.Core.Geometry;

namespace TablePro.Core.Tests.Geometry;

/// <summary>The hex fixtures came off live PostGIS, MySQL and MariaDB servers in the macOS investigation of #2532.</summary>
public sealed class WkbGeometryReaderTests
{
    private static SpatialValue Value(string hex)
    {
        var reading = WkbGeometryReader.ReadHex(hex);
        Assert.True(reading.Succeeded, reading.ToString());
        return reading.Value!;
    }

    /// <summary>MySQL prints this latitude first in ST_AsText; the storage is longitude first and must stay that way.</summary>
    [Fact]
    public void MySqlInternalIsLongitudeFirst()
    {
        var reading = WkbGeometryReader.ReadMySqlInternal(Convert.FromHexString("E6100000010100000050FC1873D79A5EC0D0D556EC2FE34240"));
        Assert.Equal(4326, reading.Value!.Srid);
        var point = Assert.IsType<PointGeometry>(reading.Value.Geometry).Point;
        Assert.Equal(-122.4194, point.X, 1e-9);
        Assert.Equal(37.7749, point.Y, 1e-9);
    }

    [Fact]
    public void MySqlInternalZeroSridReadsAsAbsent() =>
        Assert.Null(WkbGeometryReader.ReadMySqlInternal(Convert.FromHexString("00000000010100000050FC1873D79A5EC0D0D556EC2FE34240")).Value!.Srid);

    [Fact]
    public void PostGisEwkbSridFlag()
    {
        var value = Value("0101000020E610000050FC1873D79A5EC0D0D556EC2FE34240");
        Assert.Equal(4326, value.Srid);
        Assert.Equal(-122.4194, Assert.IsType<PointGeometry>(value.Geometry).Point.X, 1e-9);
    }

    [Fact]
    public void PlainWkbWithoutSrid()
    {
        var value = Value("0101000000000000000000F03F0000000000000040");
        Assert.Null(value.Srid);
        Assert.Equal(new PointGeometry(1, 2), value.Geometry);
    }

    [Fact]
    public void BigEndianByteOrder() => Assert.Equal(new PointGeometry(1, 2), Value("00000000013FF00000000000004000000000000000").Geometry);

    [Fact]
    public void NaNPointReadsAsEmpty() => Assert.Equal(EmptyGeometry.Instance, Value("0101000000000000000000F87F000000000000F87F").Geometry);

    [Theory]
    [InlineData("01E9030000000000000000F03F00000000000000400000000000000840")]
    [InlineData("0101000080000000000000F03F00000000000000400000000000000840")]
    [InlineData("0101000040000000000000F03F00000000000000400000000000000840")]
    public void IsoAndEwkbDimensionEncodings(string hex) => Assert.Equal(new PointGeometry(1, 2), Value(hex).Geometry);

    [Fact]
    public void PolygonWithInteriorRing()
    {
        var hex = "00000000010300000002000000050000000000000000000000000000000000000000000000"
            + "0000104000000000000000000000000000001040000000000000104000000000000000000000"
            + "0000000010400000000000000000000000000000000005000000000000000000F03F00000000"
            + "0000F03F0000000000000040000000000000F03F000000000000004000000000000000400000"
            + "00000000F03F0000000000000040000000000000F03F000000000000F03F";
        var polygon = Assert.IsType<PolygonGeometry>(WkbGeometryReader.ReadMySqlInternal(Convert.FromHexString(hex)).Value!.Geometry);
        Assert.Equal(2, polygon.Rings.Length);
        Assert.Equal(5, polygon.Rings[0].Length);
        Assert.Equal(new SpatialPoint(1, 1), polygon.Rings[1][0]);
    }

    /// <summary>A nested geometry declares its own byte order; inheriting the parent's is right only by luck.</summary>
    [Fact]
    public void CollectionMembersDeclareTheirOwnByteOrder()
    {
        var hex = "000000000107000000020000000101000000000000000000F03F000000000000004001020000"
            + "00020000000000000000000840000000000000104000000000000014400000000000001840";
        var collection = Assert.IsType<GeometryCollection>(WkbGeometryReader.ReadMySqlInternal(Convert.FromHexString(hex)).Value!.Geometry);
        Assert.Equal(new GeometryCollection([new PointGeometry(1, 2), new LineStringGeometry([new(3, 4), new(5, 6)])]), collection);
    }

    [Fact]
    public void TruncatedBufferIsMalformedRatherThanACrash()
    {
        Assert.Equal(SpatialReading.Fail(SpatialReadFailure.Malformed), WkbGeometryReader.ReadHex("0101000000000000000000F03F"));
        Assert.Equal(SpatialReading.Fail(SpatialReadFailure.Malformed), WkbGeometryReader.ReadHex("0101"));
    }

    [Fact]
    public void AbsurdPointCountIsRefused() =>
        Assert.Equal(SpatialReading.Fail(SpatialReadFailure.Malformed), WkbGeometryReader.ReadHex("0102000000FFFFFF7F0000000000000000"));

    [Fact]
    public void CurvedTypesAreNamed()
    {
        Assert.Equal(SpatialReading.Fail(SpatialReadFailure.Unsupported("CIRCULARSTRING")), WkbGeometryReader.ReadHex("010800000000000000"));
        Assert.Equal(SpatialReading.Fail(SpatialReadFailure.Unsupported("TIN")), WkbGeometryReader.ReadHex("011000000000000000"));
    }

    [Fact]
    public void NonHexIsNotAGeometry()
    {
        Assert.Equal(SpatialReading.Fail(SpatialReadFailure.NotGeometry), WkbGeometryReader.ReadHex("not hex at all"));
        Assert.Equal(SpatialReading.Fail(SpatialReadFailure.NotGeometry), WkbGeometryReader.ReadHex("0101000"));
    }

    [Fact]
    public void LooksLikeHexGatesTheSniffer()
    {
        Assert.True(WkbGeometryReader.LooksLikeHex("0101000020E6100000"));
        Assert.False(WkbGeometryReader.LooksLikeHex("POINT(1 2)"));
        Assert.False(WkbGeometryReader.LooksLikeHex("DEADBE"));
        Assert.False(WkbGeometryReader.LooksLikeHex("0101000020E610000"));
    }

    [Fact]
    public void GeoPackageBlobCarriesItsSrsAndSkipsTheEnvelope()
    {
        // GP, version 0, flags: little endian with a 32-byte XY envelope, SRS 4326, the envelope, then WKB POINT(1 2).
        var blob = Convert.FromHexString("47500003E6100000" + new string('0', 64) + "0101000000000000000000F03F0000000000000040");
        var value = WkbGeometryReader.ReadAny(blob).Value!;
        Assert.Equal(4326, value.Srid);
        Assert.Equal(new PointGeometry(1, 2), value.Geometry);
    }

    [Fact]
    public void ReadAnyFallsBackToTheMySqlForm()
    {
        var value = WkbGeometryReader.ReadAny(Convert.FromHexString("E6100000010100000050FC1873D79A5EC0D0D556EC2FE34240")).Value!;
        Assert.Equal(4326, value.Srid);
        Assert.IsType<PointGeometry>(value.Geometry);
    }
}
