using TablePro.Core.Geometry;

namespace TablePro.Core.Tests.Geometry;

public sealed class SpatialValueReaderTests
{
    private static SpatialGeometry Geometry(string text)
    {
        var reading = SpatialValueReader.Read(text);
        Assert.True(reading.Succeeded, reading.ToString());
        return reading.Value!.Geometry;
    }

    [Theory]
    [InlineData("SRID=4326;POINT(-122.4194 37.7749)")]
    [InlineData("0101000020E610000050FC1873D79A5EC0D0D556EC2FE34240")]
    [InlineData("""{"type":"Point","coordinates":[-122.4194,37.7749]}""")]
    [InlineData("(-122.4194,37.7749)")]
    [InlineData("37.7749,-122.4194")]
    [InlineData("""{"lat":37.7749,"lon":-122.4194}""")]
    [InlineData("""{"lat": 37.7749, "long": -122.4194}""")]
    [InlineData("[-122.4194,37.7749]")]
    public void EverySpellingOfOnePointReadsTheSame(string text)
    {
        var point = Assert.IsType<PointGeometry>(Geometry(text)).Point;
        Assert.Equal(-122.4194, point.X, 1e-9);
        Assert.Equal(37.7749, point.Y, 1e-9);
    }

    [Fact]
    public void GeoJsonCarriesWgs84() => Assert.Equal(4326, SpatialValueReader.Read("""{"type":"Point","coordinates":[1,2]}""").Value!.Srid);

    [Fact]
    public void GeoJsonPolygonWithHoleAndFeature()
    {
        Assert.Equal(2, Assert.IsType<PolygonGeometry>(Geometry("""{"type":"Polygon","coordinates":[[[0,0],[0,10],[10,10],[0,0]],[[2,2],[2,4],[4,4],[2,2]]]}""")).Rings.Length);
        Assert.Equal(new PointGeometry(1, 2), Geometry("""{"type":"Feature","geometry":{"type":"Point","coordinates":[1,2]},"properties":{"a":1}}"""));
        Assert.Equal(new PointGeometry(1, 2), Geometry("""{"type":"Point","coordinates":[1,2,3]}"""));
    }

    [Theory]
    [InlineData("((0,0),(1,0),(1,1),(0,0))", 1)]
    [InlineData("(((0,0),(4,0),(4,4),(0,0)),((1,1),(2,1),(2,2),(1,1)))", 2)]
    [InlineData("[(0,0),(4,0),(4,4),(0,0)]", 1)]
    [InlineData("[[(0,0),(4,0),(4,4),(0,0)],[(1,1),(2,1),(2,2),(1,1)]]", 2)]
    public void ClickHouseRingsAndPolygons(string text, int rings) =>
        Assert.Equal(rings, Assert.IsType<PolygonGeometry>(Geometry(text)).Rings.Length);

    [Fact]
    public void ClickHouseMultiPolygonUsesSquareBrackets() =>
        Assert.Equal(2, Assert.IsType<MultiPolygonGeometry>(Geometry("[[[(0,0),(1,0),(1,1),(0,0)]],[[(5,5),(6,5),(6,6),(5,5)]]]")).Polygons.Length);

    [Theory]
    [InlineData("200,100")]
    [InlineData("hello,world")]
    [InlineData("1,2,3")]
    [InlineData("aio1")]
    [InlineData("9q8yyk8ytpxr9q8yy")]
    public void ElasticsearchFormsRefuseWhatTheyCannotBe(string text) => Assert.Null(SpatialValueReader.ReadElasticsearchGeoPoint(text));

    [Fact]
    public void GeohashResolvesToTheCellCentre()
    {
        var point = Assert.IsType<PointGeometry>(Geometry("9q8yyk8ytpxr")).Point;
        Assert.Equal(37.7749, point.Y, 0.0001);
        Assert.Equal(-122.4194, point.X, 0.0001);
    }

    [Theory]
    [InlineData("hello")]
    [InlineData("   ")]
    [InlineData("2024-01-01")]
    public void OrdinaryTextIsRefused(string text) => Assert.Equal(SpatialReading.Fail(SpatialReadFailure.NotGeometry), SpatialValueReader.Read(text));

    [Theory]
    [InlineData("CIRCULARSTRING(0 0,1 1,2 0)", "CIRCULARSTRING")]
    [InlineData("CIRCULARSTRINGM(0 0 1,1 1 1,2 0 1)", "CIRCULARSTRING")]
    [InlineData("SRID=4326;TINZM(((0 0 0 1,0 0 1 1,0 1 0 1,0 0 0 1)))", "TIN")]
    public void UnsupportedKeywordSurvivesTheSniff(string text, string keyword) =>
        Assert.Equal(SpatialReading.Fail(SpatialReadFailure.Unsupported(keyword)), SpatialValueReader.Read(text));

    [Fact]
    public void SelfDescribingReaderRefusesGeohashesAndPairs()
    {
        Assert.False(SpatialValueReader.ReadSelfDescribing("9q8yyk8ytpxr").Succeeded);
        Assert.False(SpatialValueReader.ReadSelfDescribing("37.7749,-122.4194").Succeeded);
        Assert.True(SpatialValueReader.ReadSelfDescribing("POINT(1 2)").Succeeded);
        Assert.Equal(SpatialFailureKind.UnsupportedGeometryType, SpatialValueReader.ReadSelfDescribing("CIRCULARSTRING(0 0,1 1,2 0)").Failure.Kind);
    }

    /// <summary>The hex of a short blob is a valid geohash, so bytes never go through the text readers.</summary>
    [Fact]
    public void CellsOfBytesAreWkbAndNullsSayNothing()
    {
        Assert.Null(SpatialValueReader.ReadCell(null));
        Assert.Null(SpatialValueReader.ReadCell(string.Empty));
        Assert.Null(SpatialValueReader.ReadCell(Array.Empty<byte>()));
        Assert.False(SpatialValueReader.ReadCell(new byte[] { 0x12, 0x34 })!.Value.Succeeded);
        Assert.True(SpatialValueReader.ReadCell(Convert.FromHexString("0101000020E610000050FC1873D79A5EC0D0D556EC2FE34240"))!.Value.Succeeded);
    }
}
