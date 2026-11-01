using TablePro.Core.Geometry;

namespace TablePro.Core.Tests.Geometry;

/// <summary>Every spelling here came from PostGIS 3.6, MySQL 8.4, MariaDB 12.3 or DuckDB 1.5; they disagree, so this is the spec.</summary>
public sealed class WktGeometryReaderTests
{
    private static SpatialValue Value(string text)
    {
        var reading = WktGeometryReader.Read(text);
        Assert.True(reading.Succeeded, reading.ToString());
        return reading.Value!;
    }

    private static SpatialReadFailure Failure(string text)
    {
        var reading = WktGeometryReader.Read(text);
        Assert.False(reading.Succeeded, reading.ToString());
        return reading.Failure;
    }

    [Fact]
    public void PostGisEwktCarriesItsSrid()
    {
        var value = Value("SRID=4326;POINT(-122.4194 37.7749)");
        Assert.Equal(4326, value.Srid);
        Assert.Equal(new PointGeometry(-122.4194, 37.7749), value.Geometry);
    }

    [Fact]
    public void BareWktHasNoSrid()
    {
        var value = Value("POINT(1 2)");
        Assert.Null(value.Srid);
        Assert.Equal(new PointGeometry(1, 2), value.Geometry);
    }

    [Theory]
    [InlineData("POINT(1 2 3)")]
    [InlineData("POINTM(1 2 3)")]
    [InlineData("POINT Z (1 2 3)")]
    [InlineData("POINT ZM (1 2 3 4)")]
    [InlineData("POINT M (1 2 3)")]
    [InlineData("POINT(1 2 3 4)")]
    [InlineData("POINT (1 2)")]
    [InlineData("point (1 2)")]
    [InlineData("  POINT(1 2)\n")]
    public void DimensionSpellingsKeepTheFirstTwoOrdinates(string text) => Assert.Equal(new PointGeometry(1, 2), Value(text).Geometry);

    [Fact]
    public void NegativeAndScientificOrdinates() => Assert.Equal(new PointGeometry(-150, 2.25), Value("POINT(-1.5e2 +2.25)").Geometry);

    [Theory]
    [InlineData("MULTIPOINT(1 2,3 4)")]
    [InlineData("MULTIPOINT((1 2),(3 4))")]
    [InlineData("MULTIPOINT (1 2, 3 4)")]
    public void BothMultiPointSpellings(string text) =>
        Assert.Equal(new MultiPointGeometry([new(1, 2), new(3, 4)]), Value(text).Geometry);

    [Theory]
    [InlineData("POINT EMPTY")]
    [InlineData("GEOMETRYCOLLECTION EMPTY")]
    [InlineData("POLYGON EMPTY")]
    [InlineData("MULTIPOLYGON EMPTY")]
    [InlineData("GEOMETRYCOLLECTION()")]
    public void EmptyAtEveryLevel(string text) => Assert.Equal(EmptyGeometry.Instance, Value(text).Geometry);

    [Fact]
    public void MySqlGeomCollectionSpelling() =>
        Assert.Equal(new GeometryCollection([new PointGeometry(1, 2)]), Value("GEOMCOLLECTION(POINT(1 2))").Geometry);

    [Fact]
    public void PolygonWithHole()
    {
        var polygon = Assert.IsType<PolygonGeometry>(Value("POLYGON((0 0,4 0,4 4,0 4,0 0),(1 1,2 1,2 2,1 2,1 1))").Geometry);
        Assert.Equal(2, polygon.Rings.Length);
        Assert.Equal(5, polygon.Rings[1].Length);
        Assert.Equal(new SpatialPoint(1, 1), polygon.Rings[1][0]);
    }

    [Fact]
    public void MultiPolygon()
    {
        var multi = Assert.IsType<MultiPolygonGeometry>(Value("MULTIPOLYGON(((0 0,1 0,1 1,0 0)),((5 5,6 5,6 6,5 5)))").Geometry);
        Assert.Equal(2, multi.Polygons.Length);
        Assert.Equal(new SpatialPoint(5, 5), multi.Polygons[1][0][0]);
    }

    [Fact]
    public void NestedCollection() =>
        Assert.Equal(
            new GeometryCollection([new PointGeometry(1, 2), new LineStringGeometry([new(3, 4), new(5, 6)])]),
            Value("GEOMETRYCOLLECTION(POINT(1 2),LINESTRING(3 4,5 6))").Geometry);

    [Fact]
    public void SridPrefixOnACollection() => Assert.Equal(3857, Value("SRID=3857;GEOMETRYCOLLECTION(POINT(1 2))").Srid);

    public static TheoryData<string> Unsupported => ["CIRCULARSTRING", "COMPOUNDCURVE", "CURVEPOLYGON", "MULTICURVE", "MULTISURFACE", "POLYHEDRALSURFACE", "TIN", "TRIANGLE"];

    [Theory]
    [MemberData(nameof(Unsupported))]
    public void UnsupportedTypesAreNamed(string keyword)
    {
        Assert.Equal(SpatialReadFailure.Unsupported(keyword), Failure($"{keyword}(1 2,3 4,5 6)"));
        foreach (var tag in new[] { "M", "Z", "ZM" })
        {
            Assert.Equal(SpatialReadFailure.Unsupported(keyword), Failure($"{keyword}{tag}(0 0 1,1 1 1,2 0 1)"));
        }
    }

    [Fact]
    public void FusedTagOnAnUnsupportedTypeInPostGisSpellings()
    {
        Assert.Equal(SpatialReadFailure.Unsupported("CURVEPOLYGON"), Failure("SRID=4326;CURVEPOLYGONM(CIRCULARSTRINGM(0 0 1,4 0 1,4 4 1,0 4 1,0 0 1))"));
        Assert.Equal(SpatialReadFailure.Unsupported("COMPOUNDCURVE"), Failure("compoundcurvem((0 0 1,1 1 1))"));
        Assert.Equal(SpatialReadFailure.Unsupported("TRIANGLE"), Failure("GEOMETRYCOLLECTION(POINT(1 2),TRIANGLEM((0 0 1,1 0 1,1 1 1,0 0 1)))"));
    }

    [Fact]
    public void FusedTagLookupLeavesOrdinaryWordsAlone()
    {
        Assert.Equal(SpatialReadFailure.NotGeometry, Failure("PROGRAM(1 2)"));
        Assert.Equal(SpatialReadFailure.NotGeometry, Failure("QUIZ"));
        Assert.Equal(new MultiPointGeometry([new(1, 2), new(4, 5)]), Value("MULTIPOINTM(1 2 3,4 5 6)").Geometry);
    }

    /// <summary>EWKB reads SRID 0 as no SRID; the same value spelled as EWKT has to agree.</summary>
    [Fact]
    public void ZeroSridPrefixReadsAsNoSrid()
    {
        var expected = new SpatialValue(null, new PointGeometry(1, 2));
        Assert.Equal(expected, Value("SRID=0;POINT(1 2)"));
        Assert.Equal(expected, Value("srid = 0 ; POINT(1 2)"));
        Assert.Equal(expected, WkbGeometryReader.ReadHex("0101000020" + "00000000" + "000000000000F03F" + "0000000000000040").Value);
        Assert.Equal(SpatialProjectability.AssumedGeographic, SpatialProjection.Projectability(expected.Srid, expected.Geometry));
    }

    [Theory]
    [InlineData("hello world")]
    [InlineData("")]
    [InlineData("12345")]
    public void OrdinaryTextIsNotAGeometry(string text) => Assert.Equal(SpatialReadFailure.NotGeometry, Failure(text));

    [Theory]
    [InlineData("POINT(1 2")]
    [InlineData("POLYGON((0 0,1 1)")]
    [InlineData("POINT(1)")]
    [InlineData("POINT(1 2) extra")]
    public void TruncatedOrTrailingInputIsMalformed(string text) => Assert.Equal(SpatialReadFailure.Malformed, Failure(text));

    [Fact]
    public void LooksLikeWktGatesTheSniffer()
    {
        Assert.True(WktGeometryReader.LooksLikeWkt("POINT(1 2)"));
        Assert.True(WktGeometryReader.LooksLikeWkt("SRID=4326;MULTIPOLYGON EMPTY"));
        Assert.True(WktGeometryReader.LooksLikeWkt("point (1 2)"));
        Assert.False(WktGeometryReader.LooksLikeWkt("hello"));
        Assert.False(WktGeometryReader.LooksLikeWkt("{\"type\":\"Point\"}"));
    }
}
