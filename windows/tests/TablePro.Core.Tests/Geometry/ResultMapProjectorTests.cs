using TablePro.Core.Geometry;
using TablePro.Core.Results;

namespace TablePro.Core.Tests.Geometry;

public sealed class MapSourceDetectorTests
{
    private const string EwkbPoint = "0101000020E610000050FC1873D79A5EC0D0D556EC2FE34240";

    internal static ResultSet Column(string type, Type clr, params object?[] values) =>
        new([new ResultColumn("geom", type, clr)], values.Select(v => new[] { v }).ToList());

    [Fact]
    public void OnlySpatialColumnsAreOffered()
    {
        var result = new ResultSet(
            [new ResultColumn("id", "integer", typeof(int)), new ResultColumn("geom", "geometry", typeof(string)), new ResultColumn("name", "text", typeof(string))],
            [[1, "POINT(1 2)", "Ada"]]);
        var source = Assert.Single(MapSourceDetector.Find(result));
        Assert.Equal("geom", source.DisplayName);
        Assert.Equal(1, source.Column);
        Assert.False(source.SelfDescribingOnly);
    }

    [Fact]
    public void AResultWithNoGeometryOffersNothing() =>
        Assert.False(MapSourceDetector.HasSource(new ResultSet([new ResultColumn("name", "text", typeof(string))], [["Ada"], ["dog"]])));

    /// <summary>Oracle's SDO_GEOMETRY declares itself spatial and hands over text no reader can draw.</summary>
    [Fact]
    public void ASpatialColumnNoReaderCanReadIsNotOffered() =>
        Assert.False(MapSourceDetector.HasSource(Column("MDSYS.SDO_GEOMETRY", typeof(string),
            "MDSYS.SDO_GEOMETRY(2001,4326,MDSYS.SDO_POINT_TYPE(-122.4,37.8,NULL),NULL,NULL)",
            "MDSYS.SDO_GEOMETRY(2001,4326,MDSYS.SDO_POINT_TYPE(-122.5,37.7,NULL),NULL,NULL)")));

    /// <summary>Taking the toggle away while a page loads would make the mode appear and vanish under the reader.</summary>
    [Fact]
    public void ASpatialColumnWithNoValuesToJudgeIsStillOffered()
    {
        Assert.True(MapSourceDetector.HasSource(Column("geometry", typeof(string))));
        Assert.True(MapSourceDetector.HasSource(Column("geometry", typeof(string), null, null)));
        Assert.True(MapSourceDetector.HasSource(Column("geometry", typeof(byte[]), Array.Empty<byte>())));
    }

    [Fact]
    public void GeoJsonInADocumentColumnIsOfferedAndPlainDocumentsAreNot()
    {
        Assert.True(MapSourceDetector.HasSource(Column("json", typeof(string), """{"type":"Point","coordinates":[-122.4194,37.7749]}""")));
        Assert.False(MapSourceDetector.HasSource(Column("json", typeof(string), """{"name":"Ada","roles":["admin"]}""", """{"type":"user","features":[1,2]}""")));
        Assert.True(MapSourceDetector.HasSource(Column("json", typeof(string), "[-73.97, 40.77]", "[-73.88, 40.78]")));
        Assert.False(MapSourceDetector.HasSource(Column("json", typeof(string), "CIRCULARSTRING(0 0,1 1,2 0)")));
    }

    [Fact]
    public void ACurveColumnKeepsTheToggleSoTheMapCanNameItsType()
    {
        var curves = Column("geometry", typeof(string), Enumerable.Repeat<object?>("CIRCULARSTRING(0 0,1 1,2 0)", 4).ToArray());
        var source = Assert.Single(MapSourceDetector.Find(curves));
        var projection = ResultMapProjector.Project(curves, source, cancellationToken: TestContext.Current.CancellationToken);
        Assert.True(projection.IsEmpty);
        Assert.Contains("CIRCULARSTRING", projection.Diagnostics.EmptyReason, StringComparison.Ordinal);
        Assert.Equal(0, projection.Diagnostics.ReadableRows);
    }

    /// <summary>The hex of one to four bytes is a valid geohash; read as text, a column of short blobs drew a marker per row.</summary>
    [Fact]
    public void ShortBlobsAreNotGeohashesButWkbBytesAreOffered()
    {
        Assert.False(MapSourceDetector.HasSource(Column("geometry", typeof(byte[]), new byte[] { 0x12 }, new byte[] { 0x12, 0x34 }, new byte[] { 0x12, 0x34, 0x56, 0x78 })));
        Assert.True(MapSourceDetector.HasSource(Column("geometry", typeof(byte[]), null, Convert.FromHexString(EwkbPoint))));
        Assert.True(MapSourceDetector.HasSource(Column("blob", typeof(byte[]), Convert.FromHexString(EwkbPoint))));
    }

    [Fact]
    public void AnUntypedTextColumnIsOfferedOnlyWhenEverySampleIsSelfDescribingGeometry()
    {
        var wkt = Assert.Single(MapSourceDetector.Find(Column(string.Empty, typeof(string), "POINT(2.35 48.85)", "LINESTRING(0 0, 10 10)")));
        Assert.True(wkt.SelfDescribingOnly);
        Assert.False(MapSourceDetector.HasSource(Column("text", typeof(string), "POINT(1 2)", "Ada")));
        Assert.False(MapSourceDetector.HasSource(Column("text", typeof(string), "9q8yyk8ytpxr", "dog")));
        Assert.False(MapSourceDetector.HasSource(Column("text", typeof(string), "37.7,-122.4")));
    }

    [Fact]
    public void DuplicateColumnNamesStayDistinguishable()
    {
        var result = new ResultSet(
            [new ResultColumn("geom", "geometry", typeof(string)), new ResultColumn("geom", "geometry", typeof(string))],
            [["POINT(1 2)", "POINT(3 4)"]]);
        Assert.Equal("geom (1)|geom (2)", string.Join('|', MapSourceDetector.Find(result).Select(s => s.DisplayName)));
    }

    [Theory]
    [InlineData("Nullable(Point)", "Point")]
    [InlineData("MDSYS.SDO_GEOMETRY", "SDO_GEOMETRY")]
    [InlineData("geometry(Point,4326)", "geometry")]
    [InlineData("public.geography", "geography")]
    public void BaseTypeNamesDropWrappersSchemasAndArguments(string declared, string expected) =>
        Assert.Equal(expected, MapSourceDetector.BaseTypeName(declared));

    [Theory]
    [InlineData("lat", 1, "")]
    [InlineData("Latitude", 1, "")]
    [InlineData("pickup_lng", 2, "pickup")]
    [InlineData("pickupLat", 1, "pickup")]
    [InlineData("start_longitude", 2, "start")]
    [InlineData("x", 2, "")]
    [InlineData("y", 1, "")]
    [InlineData("latency", 0, "")]
    [InlineData("box_x", 0, "")]
    public void CoordinateRolesComeFromWordsInTheName(string name, int role, string stem)
    {
        Assert.Equal(role, MapSourceDetector.CoordinateRole(name, out var found));
        Assert.Equal(stem, found);
    }

    [Fact]
    public void LatitudeAndLongitudeColumnsWithTheSameStemArePaired()
    {
        var result = new ResultSet(
            [
                new ResultColumn("pickup_lat", "double", typeof(double)), new ResultColumn("dropoff_lat", "double", typeof(double)),
                new ResultColumn("dropoff_lng", "double", typeof(double)), new ResultColumn("pickup_lng", "double", typeof(double)),
            ],
            [[40.7, 40.8, -73.9, -74.0]]);
        var sources = MapSourceDetector.Find(result);
        Assert.Equal(2, sources.Count);
        Assert.All(sources, s => Assert.Equal(MapSourceKind.Coordinates, s.Kind));
        Assert.Equal("pickup_lat, pickup_lng", sources[0].DisplayName);
        Assert.Equal((0, 3), (sources[0].Column, sources[0].LongitudeColumn));
        Assert.Equal((1, 2), (sources[1].Column, sources[1].LongitudeColumn));
    }

    [Fact]
    public void CoordinatePairsOutOfRangeOrNotNumbersAreNotOffered()
    {
        static ResultSet Pair(Type clr, object? lat, object? lon) =>
            new([new ResultColumn("lat", "t", clr), new ResultColumn("long", "t", clr)], [[lat, lon]]);

        Assert.True(MapSourceDetector.HasSource(Pair(typeof(string), "48.85", "2.35")));
        Assert.False(MapSourceDetector.HasSource(Pair(typeof(double), 120.0, 2.35)));
        Assert.False(MapSourceDetector.HasSource(Pair(typeof(string), "north", "east")));
        Assert.False(MapSourceDetector.HasSource(Pair(typeof(string), null, null)));
        Assert.True(MapSourceDetector.HasSource(new ResultSet([new ResultColumn("lat", "real", typeof(double)), new ResultColumn("lon", "real", typeof(double))], [])));
    }
}

public sealed class ResultMapProjectorTests
{
    private static ResultSet Rows(params string?[] values) => MapSourceDetectorTests.Column("geometry", typeof(string), values);

    private static ResultMapProjection Project(ResultSet result, ShapeBudget? budget = null, IReadOnlyList<int>? order = null) =>
        ResultMapProjector.Project(result, MapSource.ForGeometry(0, "geom"), budget, order, TestContext.Current.CancellationToken);

    [Fact]
    public void EwktPointsProjectToShapesTaggedWithTheirRow()
    {
        var projection = Project(Rows("SRID=4326;POINT(-122.4194 37.7749)", "SRID=4326;POINT(-73.97 40.77)"));
        Assert.Equal(2, projection.Diagnostics.DrawnRows);
        Assert.Equal(4326, projection.Diagnostics.DrawnSrid);
        Assert.Equal(0, projection.Shapes[0].Row);
        Assert.Equal(MapShapeKind.Point, projection.Shapes[0].Kind);
        Assert.Equal(-122.4194, projection.Shapes[0].Rings[0][0].Longitude);
    }

    [Fact]
    public void AMinoritySridIsReportedRatherThanSilentlyDropped()
    {
        var projection = Project(Rows("SRID=4326;POINT(1 2)", "SRID=4326;POINT(3 4)", "SRID=3857;POINT(100 200)"));
        Assert.Equal(4326, projection.Diagnostics.DrawnSrid);
        Assert.Equal(2, projection.Diagnostics.DrawnShapes);
        Assert.Equal(1, projection.Diagnostics.OtherSridRows);
        Assert.True(projection.Diagnostics.HasAnythingToReport);
        Assert.Contains("1 row in another coordinate system is not drawn.", projection.Diagnostics.StatusText, StringComparison.Ordinal);
    }

    [Fact]
    public void WebMercatorIsInvertedAndAProjectedSridSaysWhichOne()
    {
        var mercator = Project(Rows("SRID=3857;POINT(-13627665.271218073 4547675.354340557)"));
        Assert.Equal(SpatialProjectability.WebMercator, mercator.Diagnostics.Projectability);
        Assert.Equal(-122.4194, mercator.Shapes[0].Rings[0][0].Longitude, 1e-5);

        var british = Project(Rows("SRID=27700;POINT(530000 180000)"));
        Assert.True(british.IsEmpty);
        Assert.Equal(SpatialProjectability.Unsupported(27700), british.Diagnostics.Projectability);
        Assert.Contains("SRID 27700", british.Diagnostics.EmptyReason, StringComparison.Ordinal);
    }

    [Fact]
    public void NoSridIsDrawnAsDegreesOnlyInsideTheEnvelope()
    {
        var inside = Project(Rows("POINT(1 2)", "POINT(3 4)"));
        Assert.Equal(SpatialProjectability.AssumedGeographic, inside.Diagnostics.Projectability);
        Assert.Equal(2, inside.Shapes.Count);
        Assert.Contains("no SRID", inside.Diagnostics.StatusText, StringComparison.Ordinal);

        var outside = Project(Rows("POINT(1 2)", "POINT(530000 180000)"));
        Assert.True(outside.IsEmpty);
        Assert.Equal(SpatialProjectability.Unsupported(null), outside.Diagnostics.Projectability);
    }

    [Fact]
    public void AMultipolygonRowMakesSeveralShapesThatAllNameItsRowAndAPolygonKeepsItsHoles()
    {
        var multi = Project(Rows("MULTIPOLYGON(((0 0,1 0,1 1,0 0)),((5 5,6 5,6 6,5 5)))"));
        Assert.Equal(2, multi.Shapes.Count);
        Assert.All(multi.Shapes, s => Assert.Equal(0, s.Row));
        Assert.Equal(1, multi.Diagnostics.DrawnRows);
        Assert.Equal(2, Project(Rows("POLYGON((0 0,4 0,4 4,0 4,0 0),(1 1,2 1,2 2,1 2,1 1))")).Shapes[0].Rings.Length);
    }

    [Fact]
    public void NullEmptyUnsupportedAndUnreadableRowsAreCountedNotDrawn()
    {
        var projection = Project(Rows("POINT(1 2)", null, "POINT EMPTY", "CIRCULARSTRING(0 0,1 1,2 0)", "hello"));
        Assert.Single(projection.Shapes);
        Assert.Equal(2, projection.Diagnostics.EmptyRows);
        Assert.Equal(1, projection.Diagnostics.UnsupportedTypes["CIRCULARSTRING"]);
        Assert.Equal(1, projection.Diagnostics.UnreadableRows);
    }

    [Fact]
    public void OnlyTheGivenRowOrderIsDrawn()
    {
        var projection = Project(Rows("POINT(1 1)", "POINT(2 2)", "POINT(3 3)"), order: [2, 0]);
        Assert.Equal("2,0", string.Join(',', projection.Shapes.Select(s => s.Row)));
    }

    [Fact]
    public void ATieBetweenSridsPrefersTheNamedOne()
    {
        Assert.True(ResultMapProjector.TryGetMajoritySrid(new Dictionary<int, int> { [4326] = 1 }, 1, out var tie));
        Assert.Equal(4326, tie);
        Assert.True(ResultMapProjector.TryGetMajoritySrid(new Dictionary<int, int> { [4326] = 1, [3857] = 2 }, 0, out var most));
        Assert.Equal(3857, most);
        Assert.True(ResultMapProjector.TryGetMajoritySrid(new Dictionary<int, int>(), 3, out var unnamed));
        Assert.Null(unnamed);
        Assert.False(ResultMapProjector.TryGetMajoritySrid(new Dictionary<int, int>(), 0, out _));
    }

    [Fact]
    public void WkbBytesAreDrawnAndShortBlobsBesideThemAreUnreadable()
    {
        var table = MapSourceDetectorTests.Column("geometry", typeof(byte[]),
            new byte[] { 0x12, 0x34 }, Convert.FromHexString("0101000020E610000050FC1873D79A5EC0D0D556EC2FE34240"), new byte[] { 0x12, 0x34, 0x56, 0x78 }, Array.Empty<byte>());
        var projection = Project(table);
        Assert.Equal(1, Assert.Single(projection.Shapes).Row);
        Assert.Equal(4326, projection.Diagnostics.DrawnSrid);
        Assert.Equal(2, projection.Diagnostics.UnreadableRows);
        Assert.Equal(1, projection.Diagnostics.EmptyRows);
    }

    /// <summary>A budget checked once per row let one MULTIPOINT put any number of shapes on the map.</summary>
    [Fact]
    public void OneGeometryCannotSpendMoreThanTheWholeBudget()
    {
        var many = string.Join(',', Enumerable.Range(0, 40).Select(i => FormattableString.Invariant($"{-122.0 + (i / 100.0)} 37.5")));
        var projection = Project(Rows($"MULTIPOINT({many})"), new ShapeBudget(5, 1_000));
        Assert.Equal(5, projection.Shapes.Count);
        Assert.Equal(1, projection.Diagnostics.CappedRows);
    }

    [Fact]
    public void TheVertexBudgetStopsARunTheShapeBudgetWouldAllow()
    {
        var run = string.Join(',', Enumerable.Range(0, 30).Select(i => FormattableString.Invariant($"{-122.0 + (i / 100.0)} 37.5")));
        var projection = Project(Rows($"LINESTRING({run})", $"LINESTRING({run})"), new ShapeBudget(100, 30));
        Assert.Single(projection.Shapes);
        Assert.Equal(1, projection.Diagnostics.CappedRows);
    }

    [Fact]
    public void AMemberTheMapCannotPlaceIsCountedWhileTheRestOfTheRowIsDrawn()
    {
        var projection = Project(Rows("SRID=4326;MULTIPOLYGON(((179 50,181 50,181 51,179 50)),((10 10,11 10,11 11,10 10)))", "SRID=4326;POINT(1 2)"));
        Assert.Equal(2, projection.Shapes.Count);
        Assert.Equal(2, projection.Diagnostics.DrawnRows);
        Assert.Equal(1, projection.Diagnostics.DroppedParts);
        Assert.Equal(0, projection.Diagnostics.UnreadableRows);
        Assert.True(projection.Diagnostics.HasAnythingToReport);
    }

    [Fact]
    public void ARowThatDrawsNothingIsCountedAsARowNotAsParts()
    {
        var projection = Project(Rows("SRID=4326;MULTIPOINT(181 50,182 50)", "SRID=4326;POINT(1 2)"));
        Assert.Single(projection.Shapes);
        Assert.Equal(1, projection.Diagnostics.UnreadableRows);
        Assert.Equal(0, projection.Diagnostics.DroppedParts);
    }

    [Fact]
    public void CoordinatePairsDrawAPointPerRowAndCountTheRest()
    {
        var result = new ResultSet(
            [new ResultColumn("lat", "real", typeof(double)), new ResultColumn("lon", "real", typeof(double))],
            [[48.85, 2.35], [null, 1.0], [95.0, 1.0], [51.5, -0.12]]);
        var projection = ResultMapProjector.Project(result, MapSource.ForCoordinates(0, 1, "lat, lon"), cancellationToken: TestContext.Current.CancellationToken);
        Assert.Equal("0,3", string.Join(',', projection.Shapes.Select(s => s.Row)));
        Assert.Equal(new GeographicCoordinate(2.35, 48.85), projection.Shapes[0].Rings[0][0]);
        Assert.Equal(1, projection.Diagnostics.EmptyRows);
        Assert.Equal(1, projection.Diagnostics.UnreadableRows);
        Assert.StartsWith("Drawing 2 points from latitude and longitude columns.", projection.Diagnostics.StatusText, StringComparison.Ordinal);
    }

    [Fact]
    public void ACancelledProjectionStops()
    {
        using var cancelled = new CancellationTokenSource();
        cancelled.Cancel();
        Assert.Throws<OperationCanceledException>(() => ResultMapProjector.Project(Rows("POINT(1 2)"), MapSource.ForGeometry(0, "geom"), cancellationToken: cancelled.Token));
    }
}

public sealed class MapSceneTests
{
    private static MapScene Scene(params string[] values)
    {
        var result = MapSourceDetectorTests.Column("geometry", typeof(string), values);
        return MapScene.Build(ResultMapProjector.Project(result, MapSource.ForGeometry(0, "geom"), cancellationToken: TestContext.Current.CancellationToken), TestContext.Current.CancellationToken);
    }

    private static (double X, double Y) World(double longitude, double latitude) => WebMercator.ToWorld(new GeographicCoordinate(longitude, latitude));

    [Fact]
    public void WebMercatorPutsNullIslandInTheMiddleAndRoundTrips()
    {
        var (x, y) = World(0, 0);
        Assert.Equal(0.5, x, 1e-12);
        Assert.Equal(0.5, y, 1e-12);
        var back = WebMercator.FromWorld(World(-122.4194, 37.7749).X, World(-122.4194, 37.7749).Y);
        Assert.Equal(-122.4194, back.Longitude, 1e-9);
        Assert.Equal(37.7749, back.Latitude, 1e-9);
    }

    [Fact]
    public void EveryPolygonsCentreResolvesBackToItsRowAndAHoleMisses()
    {
        var scene = Scene("POLYGON((0 0,10 0,10 10,0 10,0 0),(4 4,6 4,6 6,4 6,4 4))", "POLYGON((20 20,30 20,30 30,20 30,20 20))");
        var (x, y) = World(25, 25);
        Assert.Equal(1, scene.HitTest(x, y, 0));
        (x, y) = World(2, 2);
        Assert.Equal(0, scene.HitTest(x, y, 0));
        (x, y) = World(5, 5);
        Assert.Equal(-1, scene.HitTest(x, y, 0));
        (x, y) = World(50, 50);
        Assert.Equal(-1, scene.HitTest(x, y, 0));
        Assert.Equal(-1, MapScene.Empty.HitTest(x, y, 1));
    }

    [Fact]
    public void OverlappingShapesResolveToTheTopmostAndPointsSitOverPolygons()
    {
        var scene = Scene("POLYGON((0 0,10 0,10 10,0 10,0 0))", "POLYGON((0 0,10 0,10 10,0 10,0 0))", "POINT(5 5)");
        var (x, y) = World(5, 5);
        Assert.Equal(2, scene.HitTest(x, y, 1e-6));
        (x, y) = World(2, 2);
        Assert.Equal(1, scene.HitTest(x, y, 1e-6));
    }

    [Fact]
    public void AClickOnALineHitsItAndOneWellOffItDoesNot()
    {
        var scene = Scene("LINESTRING(0 0,10 0)");
        var (x, y) = World(5, 0.0001);
        Assert.Equal(0, scene.HitTest(x, y, 1e-5));
        (x, y) = World(5, 3);
        Assert.Equal(-1, scene.HitTest(x, y, 1e-5));
    }

    [Fact]
    public void FitKeepsThirtyTwoPointsOnEveryEdge()
    {
        var scene = Scene("POINT(0 0)", "POINT(10 10)");
        var view = MapView.Fit(scene.Extent, 800, 600);
        var (left, top) = view.ToScreen(scene.Extent.Left, scene.Extent.Top);
        var (right, bottom) = view.ToScreen(scene.Extent.Right, scene.Extent.Bottom);
        Assert.Equal(400, (left + right) / 2, 1e-6);
        Assert.Equal(300, (top + bottom) / 2, 1e-6);
        Assert.Equal(32, Math.Min(top, 600 - bottom), 1e-6);
    }

    /// <summary>A lone point folds to a zero-size extent, which a naive fit would show at the deepest zoom.</summary>
    [Fact]
    public void ALonePointIsShownWithAFewHundredMetresAroundIt()
    {
        var scene = Scene("POINT(2.35 48.85)");
        var view = MapView.Fit(scene.Extent, 800, 600);
        var metresPerPixel = WebMercator.EarthCircumference * Math.Cos(48.85 * Math.PI / 180) / view.Scale;
        Assert.InRange(metresPerPixel * 600, 700, 900);
        var (x, y) = view.ToScreen(scene.Extent.Left, scene.Extent.Top);
        Assert.Equal(400, x, 1e-6);
        Assert.Equal(300, y, 1e-6);
    }

    [Fact]
    public void ZoomKeepsThePointUnderTheCursorAndClampsTheScale()
    {
        var view = new MapView(1000, 10, 20);
        var before = view.ToWorld(300, 200);
        var zoomed = view.ZoomAt(2, 300, 200);
        var after = zoomed.ToWorld(300, 200);
        Assert.Equal(before.X, after.X, 1e-12);
        Assert.Equal(before.Y, after.Y, 1e-12);
        Assert.Equal(MapView.MinimumScale, view.ZoomAt(1e-9, 0, 0).Scale);
        Assert.Equal(MapView.MaximumScale, view.ZoomAt(1e12, 0, 0).Scale);
    }
}
