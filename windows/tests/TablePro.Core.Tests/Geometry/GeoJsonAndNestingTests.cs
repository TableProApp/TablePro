using System.Text;
using TablePro.Core.Geometry;

namespace TablePro.Core.Tests.Geometry;

public sealed class GeoJsonGeometryReaderTests
{
    private static SpatialGeometry Geometry(string text)
    {
        var reading = GeoJsonGeometryReader.Read(text);
        Assert.True(reading.Succeeded, text);
        return reading.Value!.Geometry;
    }

    /// <summary>Elasticsearch documents geo_shape types in lowercase and returns a document as indexed.</summary>
    [Theory]
    [InlineData("Point")]
    [InlineData("point")]
    [InlineData("POINT")]
    [InlineData("pOiNt")]
    public void PointReadsInAnyCase(string type) =>
        Assert.Equal(new PointGeometry(-73.97, 40.77), Geometry($$"""{"type":"{{type}}","coordinates":[-73.97,40.77]}"""));

    [Fact]
    public void EveryLowercaseTypeKeepsItsOwnShape()
    {
        SpatialPoint first = new(0, 0), second = new(1, 1);
        Assert.Equal(new MultiPointGeometry([first, second]), Geometry("""{"type":"multipoint","coordinates":[[0,0],[1,1]]}"""));
        Assert.Equal(new LineStringGeometry([first, second]), Geometry("""{"type":"linestring","coordinates":[[0,0],[1,1]]}"""));
        Assert.Equal(new MultiLineStringGeometry([[first, second]]), Geometry("""{"type":"multilinestring","coordinates":[[[0,0],[1,1]]]}"""));
        Assert.Equal(new MultiPolygonGeometry([[[first, second, new(1, 0), first]]]), Geometry("""{"type":"multipolygon","coordinates":[[[[0,0],[1,1],[1,0],[0,0]]]]}"""));
    }

    [Fact]
    public void CollectionsAndFeaturesUnwrap()
    {
        Assert.Equal(
            new GeometryCollection([new PointGeometry(1, 2), new LineStringGeometry([new(3, 4), new(5, 6)])]),
            Geometry("""{"type":"geometrycollection","geometries":[{"type":"point","coordinates":[1,2]},{"type":"LINESTRING","coordinates":[[3,4],[5,6]]}]}"""));
        Assert.Equal(new PointGeometry(1, 2), Geometry("""{"type":"FEATURECOLLECTION","features":[{"type":"FEATURE","geometry":{"type":"POINT","coordinates":[1,2]}}]}"""));
    }

    [Theory]
    [InlineData("""{"type":"envelope","coordinates":[[-10,10],[10,-10]]}""")]
    [InlineData("""{"type":"circle","coordinates":[-10,10],"radius":"10m"}""")]
    [InlineData("""{"type":"points","coordinates":[1,2]}""")]
    [InlineData("""{"type":"","coordinates":[1,2]}""")]
    [InlineData("""{"type":"Point","coordinates":[1,2]""")]
    public void NamesWithNoShapeStayRefused(string json) =>
        Assert.Equal(SpatialReading.Fail(SpatialReadFailure.NotGeometry), GeoJsonGeometryReader.Read(json));
}

/// <summary>
/// Every format lets a collection nest without limit and each level is a stack frame, so each reader refuses past the
/// shared limit. The innermost point spends a level, so the deepest accepted value is the limit less one collection.
/// </summary>
public sealed class SpatialNestingDepthTests
{
    private static string NestedWkt(int depth) =>
        new StringBuilder().Insert(0, "GEOMETRYCOLLECTION(", depth).Append("POINT(1 2)").Append(')', depth).ToString();

    private static string NestedGeoJson(int depth) =>
        new StringBuilder().Insert(0, """{"type":"GeometryCollection","geometries":[""", depth).Append("""{"type":"Point","coordinates":[1,2]}""")
            .Append(string.Concat(Enumerable.Repeat("]}", depth))).ToString();

    [Fact]
    public void WktAcceptsUpToTheLimitAndRefusesPastIt()
    {
        Assert.True(WktGeometryReader.Read(NestedWkt(SpatialLimits.MaximumNestingDepth - 1)).Succeeded);
        Assert.Equal(SpatialReading.Fail(SpatialReadFailure.Malformed), WktGeometryReader.Read(NestedWkt(SpatialLimits.MaximumNestingDepth)));
        Assert.Equal(SpatialReading.Fail(SpatialReadFailure.Malformed), WktGeometryReader.Read(NestedWkt(5_000)));
    }

    [Fact]
    public void GeoJsonAcceptsUpToTheLimitAndRefusesDeepNesting()
    {
        Assert.True(GeoJsonGeometryReader.Read(NestedGeoJson(SpatialLimits.MaximumNestingDepth - 1)).Succeeded);
        Assert.Equal(SpatialReading.Fail(SpatialReadFailure.NotGeometry), GeoJsonGeometryReader.Read(NestedGeoJson(5_000)));
    }

    [Fact]
    public void WkbRefusesNestingPastTheLimit()
    {
        var bytes = new List<byte>();
        for (var i = 0; i < 5_000; i++)
        {
            bytes.AddRange([0x01, 0x07, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00]);
        }

        bytes.AddRange([0x01, 0x01, 0x00, 0x00, 0x00]);
        bytes.AddRange(new byte[16]);
        Assert.Equal(SpatialReading.Fail(SpatialReadFailure.Malformed), WkbGeometryReader.Read(bytes.ToArray()));
    }

    [Theory]
    [InlineData('[', ']')]
    [InlineData('(', ')')]
    public void TupleRefusesDeepNestingWithoutRecursingIntoIt(char open, char close)
    {
        var text = new string(open, 100_000) + new string(close, 100_000);
        Assert.Null(SpatialValueReader.ReadClickHouseTuple(text));
        Assert.Equal(SpatialReading.Fail(SpatialReadFailure.NotGeometry), SpatialValueReader.Read(text));
    }

    [Fact]
    public void TupleRefusesDeepNestingAroundAPoint() =>
        Assert.Equal(SpatialReading.Fail(SpatialReadFailure.NotGeometry), SpatialValueReader.Read(new string('[', 100_000) + "(1,2)" + new string(']', 100_000)));

    [Fact]
    public void TupleStillReadsTheDeepestRealValue()
    {
        var multi = Assert.IsType<MultiPolygonGeometry>(SpatialValueReader.ReadClickHouseTuple("[[[(0,0),(1,0),(1,1),(0,0)],[(0.2,0.2),(0.4,0.2),(0.4,0.4),(0.2,0.2)]]]")!.Geometry);
        Assert.Single(multi.Polygons);
        Assert.Equal(2, multi.Polygons[0].Length);
    }
}

public sealed class SpatialProjectionTests
{
    private static readonly PointGeometry SanFrancisco = new(-122.4194, 37.7749);

    [Theory]
    [InlineData(4326)]
    [InlineData(4269)]
    [InlineData(4979)]
    [InlineData(4258)]
    [InlineData(4283)]
    [InlineData(7844)]
    [InlineData(4490)]
    [InlineData(4674)]
    [InlineData(6318)]
    [InlineData(6668)]
    public void GeographicSridsDrawDirectly(int srid) => Assert.Equal(SpatialProjectability.Geographic, SpatialProjection.Projectability(srid, SanFrancisco));

    [Theory]
    [InlineData(3857)]
    [InlineData(900913)]
    [InlineData(102100)]
    [InlineData(102113)]
    [InlineData(3785)]
    public void WebMercatorAliases(int srid) => Assert.Equal(SpatialProjectability.WebMercator, SpatialProjection.Projectability(srid, SanFrancisco));

    [Fact]
    public void WebMercatorInverseMatchesProj()
    {
        // Verified against PROJ 9.8.1 for the macOS suite.
        var coordinate = SpatialProjection.Project(new SpatialPoint(-13_627_665.271218073, 4_547_675.354340557), SpatialProjectability.WebMercator)!.Value;
        Assert.Equal(-122.4194, coordinate.Longitude, 1e-9);
        Assert.Equal(37.7749, coordinate.Latitude, 1e-9);
        var origin = SpatialProjection.Project(new SpatialPoint(0, 0), SpatialProjectability.WebMercator)!.Value;
        Assert.Equal(0, origin.Longitude, 1e-12);
        Assert.Equal(0, origin.Latitude, 1e-12);
    }

    [Fact]
    public void AbsentSridIsDecidedByTheValues()
    {
        Assert.Equal(SpatialProjectability.AssumedGeographic, SpatialProjection.Projectability(null, SanFrancisco));
        Assert.Equal(SpatialProjectability.Unsupported(null), SpatialProjection.Projectability(null, new PointGeometry(530000, 180000)));
        Assert.Equal(SpatialProjectability.Unsupported(null), SpatialProjection.Projectability(null, new LineStringGeometry([new(1, 1), new(2, 2), new(500, 2)])));
        Assert.Equal(SpatialProjectability.Unsupported(null), SpatialProjection.Projectability(null, EmptyGeometry.Instance));
    }

    [Fact]
    public void ProjectedSridIsRefusedByNumber()
    {
        Assert.Equal(SpatialProjectability.Unsupported(32633), SpatialProjection.Projectability(32633, SanFrancisco));
        Assert.Null(SpatialProjection.Project(SanFrancisco.Point, SpatialProjectability.Unsupported(32633)));
    }

    [Theory]
    [InlineData(180.0000001, 0)]
    [InlineData(0, 91)]
    [InlineData(-181, 0)]
    [InlineData(double.NaN, 0)]
    [InlineData(double.PositiveInfinity, 0)]
    public void OutOfRangeCoordinatesAreRejected(double x, double y) => Assert.Null(SpatialProjection.Project(new SpatialPoint(x, y), SpatialProjectability.Geographic));

    [Fact]
    public void EnvelopeEdgesAreValidAndLongitudeStaysInX()
    {
        Assert.NotNull(SpatialProjection.Project(new SpatialPoint(180, 90), SpatialProjectability.Geographic));
        Assert.NotNull(SpatialProjection.Project(new SpatialPoint(-180, -90), SpatialProjectability.Geographic));
        Assert.Equal(new GeographicCoordinate(-122.4194, 37.7749), SpatialProjection.Project(SanFrancisco.Point, SpatialProjectability.Geographic));
    }
}
