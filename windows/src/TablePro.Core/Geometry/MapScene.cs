namespace TablePro.Core.Geometry;

/// <summary>
/// Spherical Mercator on the unit square, as web maps lay out the world: x runs east from the antimeridian and y south
/// from the top edge. Latitudes past the projection's limit are clamped to it, since Mercator puts the poles at infinity.
/// </summary>
public static class WebMercator
{
    public const double MaximumLatitude = 85.05112878;

    public const double EarthCircumference = 40_075_016.686;

    public static (double X, double Y) ToWorld(GeographicCoordinate coordinate)
    {
        var latitude = Math.Clamp(coordinate.Latitude, -MaximumLatitude, MaximumLatitude) * Math.PI / 180;
        var x = (coordinate.Longitude + 180) / 360;
        var y = (1 - (Math.Log(Math.Tan(latitude) + (1 / Math.Cos(latitude))) / Math.PI)) / 2;
        return (x, y);
    }

    public static GeographicCoordinate FromWorld(double x, double y)
    {
        var longitude = (x * 360) - 180;
        var latitude = Math.Atan(Math.Sinh(Math.PI * (1 - (2 * y)))) * 180 / Math.PI;
        return new GeographicCoordinate(longitude, latitude);
    }
}

/// <summary>An axis-aligned rectangle in world units.</summary>
public readonly record struct WorldRect(double Left, double Top, double Right, double Bottom)
{
    public static readonly WorldRect None = new(double.PositiveInfinity, double.PositiveInfinity, double.NegativeInfinity, double.NegativeInfinity);

    public double Width => Right - Left;

    public double Height => Bottom - Top;

    public bool IsNone => Left > Right || Top > Bottom;

    public WorldRect Include(double x, double y) => new(Math.Min(Left, x), Math.Min(Top, y), Math.Max(Right, x), Math.Max(Bottom, y));

    public WorldRect Union(WorldRect other) =>
        other.IsNone ? this : IsNone ? other : new(Math.Min(Left, other.Left), Math.Min(Top, other.Top), Math.Max(Right, other.Right), Math.Max(Bottom, other.Bottom));

    public bool Contains(double x, double y, double slop = 0) =>
        x >= Left - slop && x <= Right + slop && y >= Top - slop && y <= Bottom + slop;

    public bool Intersects(WorldRect other) => !IsNone && !other.IsNone && Left <= other.Right && other.Left <= Right && Top <= other.Bottom && other.Top <= Bottom;
}

/// <summary>Where the world sits on screen: a screen point is the world point times <see cref="Scale"/> plus the offset.</summary>
public readonly record struct MapView(double Scale, double OffsetX, double OffsetY)
{
    /// <summary>The whole world 64 pixels across, which is as far out as orientation is still useful.</summary>
    public const double MinimumScale = 64;

    /// <summary>About building level; the shapes come from a database rather than tiles, so nothing finer exists.</summary>
    public const double MaximumScale = 256 * (1 << 22);

    /// <summary>The margin a fitted result keeps on every edge, the same 32 points the macOS map keeps.</summary>
    public const double FitPadding = 32;

    /// <summary>How much ground a lone point is shown with, which is its margin, as on macOS.</summary>
    public const double LonePointMetres = 400;

    public (double X, double Y) ToScreen(double worldX, double worldY) => ((worldX * Scale) + OffsetX, (worldY * Scale) + OffsetY);

    public (double X, double Y) ToWorld(double screenX, double screenY) => ((screenX - OffsetX) / Scale, (screenY - OffsetY) / Scale);

    public MapView Pan(double dx, double dy) => this with { OffsetX = OffsetX + dx, OffsetY = OffsetY + dy };

    /// <summary>Zooms by <paramref name="factor"/> keeping the world point under the screen point where it is.</summary>
    public MapView ZoomAt(double factor, double screenX, double screenY)
    {
        var scale = Math.Clamp(Scale * factor, MinimumScale, MaximumScale);
        var (worldX, worldY) = ToWorld(screenX, screenY);
        return new MapView(scale, screenX - (worldX * scale), screenY - (worldY * scale));
    }

    /// <summary>Fits <paramref name="extent"/> into a viewport, giving a lone point its few hundred metres of ground.</summary>
    public static MapView Fit(WorldRect extent, double width, double height, double padding = FitPadding)
    {
        if (extent.IsNone || width <= 0 || height <= 0)
        {
            return new MapView(Math.Max(MinimumScale, Math.Min(width, height)), (width - Math.Min(width, height)) / 2, (height - Math.Min(width, height)) / 2);
        }

        if (extent.Width <= 0 && extent.Height <= 0)
        {
            var latitude = WebMercator.FromWorld(extent.Left, extent.Top).Latitude * Math.PI / 180;
            var half = LonePointMetres / (WebMercator.EarthCircumference * Math.Max(Math.Cos(latitude), 1e-6));
            extent = new WorldRect(extent.Left - half, extent.Top - half, extent.Right + half, extent.Bottom + half);
            padding = 0;
        }

        var usableWidth = Math.Max(1, width - (2 * padding));
        var usableHeight = Math.Max(1, height - (2 * padding));
        var scaleX = extent.Width > 0 ? usableWidth / extent.Width : double.PositiveInfinity;
        var scaleY = extent.Height > 0 ? usableHeight / extent.Height : double.PositiveInfinity;
        var scale = Math.Clamp(Math.Min(scaleX, scaleY), MinimumScale, MaximumScale);
        var centerX = (extent.Left + extent.Right) / 2;
        var centerY = (extent.Top + extent.Bottom) / 2;
        return new MapView(scale, (width / 2) - (centerX * scale), (height / 2) - (centerY * scale));
    }
}

/// <summary>One shape in world units: each ring is x and y interleaved, so a ring is one array.</summary>
public sealed class MapSceneShape(int row, MapShapeKind kind, double[][] rings, WorldRect bounds)
{
    public int Row { get; } = row;

    public MapShapeKind Kind { get; } = kind;

    public double[][] Rings { get; } = rings;

    public WorldRect Bounds { get; } = bounds;
}

/// <summary>
/// A projection in world units, built once per result off the UI thread so panning and zooming only transform it.
/// Shapes are kept by kind in draw order: polygons, then lines, then points on top.
/// </summary>
public sealed class MapScene
{
    private MapScene(MapSceneShape[] polygons, MapSceneShape[] lines, MapSceneShape[] points, WorldRect extent, int rows)
    {
        Polygons = polygons;
        Lines = lines;
        Points = points;
        Extent = extent;
        RowCount = rows;
    }

    public static MapScene Empty { get; } = new([], [], [], WorldRect.None, 0);

    public IReadOnlyList<MapSceneShape> Polygons { get; }

    public IReadOnlyList<MapSceneShape> Lines { get; }

    public IReadOnlyList<MapSceneShape> Points { get; }

    public WorldRect Extent { get; }

    /// <summary>How many distinct rows the shapes come from.</summary>
    public int RowCount { get; }

    public int ShapeCount => Polygons.Count + Lines.Count + Points.Count;

    public static MapScene Build(ResultMapProjection projection, CancellationToken cancellationToken = default)
    {
        ArgumentNullException.ThrowIfNull(projection);
        var polygons = new List<MapSceneShape>();
        var lines = new List<MapSceneShape>();
        var points = new List<MapSceneShape>();
        var extent = WorldRect.None;
        var rows = new HashSet<int>();
        foreach (var shape in projection.Shapes)
        {
            cancellationToken.ThrowIfCancellationRequested();
            var bounds = WorldRect.None;
            var rings = new double[shape.Rings.Length][];
            for (var r = 0; r < rings.Length; r++)
            {
                var source = shape.Rings[r];
                var ring = new double[source.Length * 2];
                for (var i = 0; i < source.Length; i++)
                {
                    var (x, y) = WebMercator.ToWorld(source[i]);
                    ring[2 * i] = x;
                    ring[(2 * i) + 1] = y;
                    bounds = bounds.Include(x, y);
                }

                rings[r] = ring;
            }

            var scene = new MapSceneShape(shape.Row, shape.Kind, rings, bounds);
            (shape.Kind switch { MapShapeKind.Polygon => polygons, MapShapeKind.Polyline => lines, _ => points }).Add(scene);
            extent = extent.Union(bounds);
            rows.Add(shape.Row);
        }

        return new MapScene([.. polygons], [.. lines], [.. points], extent, rows.Count);
    }

    /// <summary>
    /// The row under a world point, or -1. Topmost first, as drawn: points over lines over polygons, later over earlier.
    /// A point or line is matched within <paramref name="slop"/> world units, since a line is one pixel of target.
    /// </summary>
    public int HitTest(double x, double y, double slop)
    {
        for (var i = Points.Count - 1; i >= 0; i--)
        {
            var ring = Points[i].Rings[0];
            var dx = ring[0] - x;
            var dy = ring[1] - y;
            if ((dx * dx) + (dy * dy) <= slop * slop)
            {
                return Points[i].Row;
            }
        }

        for (var i = Lines.Count - 1; i >= 0; i--)
        {
            var line = Lines[i];
            if (line.Bounds.Contains(x, y, slop) && NearRun(line.Rings[0], x, y, slop))
            {
                return line.Row;
            }
        }

        for (var i = Polygons.Count - 1; i >= 0; i--)
        {
            var polygon = Polygons[i];
            if (polygon.Bounds.Contains(x, y) && InsideEvenOdd(polygon.Rings, x, y))
            {
                return polygon.Row;
            }
        }

        return -1;
    }

    private static bool NearRun(double[] run, double x, double y, double slop)
    {
        var limit = slop * slop;
        for (var i = 2; i < run.Length; i += 2)
        {
            if (SegmentDistanceSquared(run[i - 2], run[i - 1], run[i], run[i + 1], x, y) <= limit)
            {
                return true;
            }
        }

        return false;
    }

    private static double SegmentDistanceSquared(double ax, double ay, double bx, double by, double px, double py)
    {
        var dx = bx - ax;
        var dy = by - ay;
        var length = (dx * dx) + (dy * dy);
        var t = length == 0 ? 0 : Math.Clamp((((px - ax) * dx) + ((py - ay) * dy)) / length, 0, 1);
        var cx = ax + (t * dx) - px;
        var cy = ay + (t * dy) - py;
        return (cx * cx) + (cy * cy);
    }

    /// <summary>
    /// Even-odd across every ring, not non-zero winding: a hole often winds the same way as its exterior, and the non-zero
    /// rule would count a click inside the hole as inside the polygon.
    /// </summary>
    private static bool InsideEvenOdd(double[][] rings, double x, double y)
    {
        var inside = false;
        foreach (var ring in rings)
        {
            var count = ring.Length / 2;
            for (int i = 0, j = count - 1; i < count; j = i++)
            {
                double xi = ring[2 * i], yi = ring[(2 * i) + 1], xj = ring[2 * j], yj = ring[(2 * j) + 1];
                if ((yi > y) != (yj > y) && x < ((xj - xi) * (y - yi) / (yj - yi)) + xi)
                {
                    inside = !inside;
                }
            }
        }

        return inside;
    }
}
