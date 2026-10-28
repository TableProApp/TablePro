using System.Globalization;
using TablePro.Core.Results;

namespace TablePro.Core.Geometry;

public enum MapShapeKind
{
    Point,
    Polyline,
    Polygon,
}

/// <summary>
/// One drawable shape in WGS84 degrees, tagged with the row it came from. A row can make several shapes, and each keeps
/// the row, so a click on any part of a multipolygon selects the row that owns it.
/// </summary>
public sealed class ResultMapShape(int row, MapShapeKind kind, GeographicCoordinate[][] rings)
{
    public int Row { get; } = row;

    public MapShapeKind Kind { get; } = kind;

    /// <summary>A point holds one coordinate, a polyline one run, a polygon its exterior ring and then any holes.</summary>
    public GeographicCoordinate[][] Rings { get; } = rings;
}

/// <summary>What is left of the map's allowance of shapes and vertices.</summary>
public struct ShapeBudget(int shapes, int vertices)
{
    public int Shapes { get; private set; } = shapes;

    public int Vertices { get; private set; } = vertices;

    public bool IsExhausted { get; private set; }

    /// <summary>Takes one shape of <paramref name="count"/> vertices, or marks the budget spent when it does not fit.</summary>
    public bool Take(int count)
    {
        if (Shapes <= 0 || Vertices < count)
        {
            IsExhausted = true;
            return false;
        }

        Shapes--;
        Vertices -= count;
        return true;
    }
}

/// <summary>What the map could not draw, and why, in the terms the pane has to say out loud.</summary>
public sealed class ResultMapDiagnostics
{
    private readonly Dictionary<string, int> _unsupportedTypes = new(StringComparer.Ordinal);

    public int DrawnShapes { get; internal set; }

    public int DrawnRows { get; internal set; }

    public int ConsideredRows { get; internal set; }

    public SpatialProjectability Projectability { get; internal set; } = SpatialProjectability.Unsupported(null);

    public int? DrawnSrid { get; internal set; }

    /// <summary>True when the shapes came from a latitude and a longitude column rather than a geometry.</summary>
    public bool FromCoordinateColumns { get; internal set; }

    /// <summary>Rows in a coordinate system other than the majority's, counted because a map cannot show two at once.</summary>
    public int OtherSridRows { get; internal set; }

    /// <summary>Keyword to row count, for types no parser turns into line segments.</summary>
    public IReadOnlyDictionary<string, int> UnsupportedTypes => _unsupportedTypes;

    public int UnreadableRows { get; internal set; }

    public int EmptyRows { get; internal set; }

    /// <summary>
    /// Rows that read as a non-empty geometry, whatever happened to them afterwards. Asked before the coordinate system is
    /// blamed, since <see cref="Projectability"/> defaults to unsupported and a column where nothing parsed looks the same.
    /// </summary>
    public int ReadableRows { get; internal set; }

    /// <summary>Rows past the shape or vertex budget; null when nothing was capped.</summary>
    public int? CappedRows { get; internal set; }

    /// <summary>Members of drawn rows that are not on the map: unplaceable coordinates, or too few vertices.</summary>
    public int DroppedParts { get; internal set; }

    public bool HasAnythingToReport =>
        OtherSridRows > 0 || _unsupportedTypes.Count > 0 || UnreadableRows > 0 || CappedRows is not null || DroppedParts > 0;

    internal void CountUnsupported(string keyword) => _unsupportedTypes[keyword] = _unsupportedTypes.GetValueOrDefault(keyword) + 1;

    /// <summary>What the map shows and what it left out, as sentences rather than bare counts.</summary>
    public string StatusText
    {
        get
        {
            var culture = CultureInfo.CurrentCulture;
            var parts = new List<string>();
            if (FromCoordinateColumns)
            {
                parts.Add(string.Create(culture, $"Drawing {DrawnShapes:N0} points from latitude and longitude columns."));
            }
            else if (DrawnSrid is { } srid)
            {
                parts.Add(string.Create(culture, $"Drawing {DrawnShapes:N0} shapes in SRID {srid.ToString(CultureInfo.InvariantCulture)}."));
            }
            else if (Projectability.Kind == ProjectabilityKind.AssumedGeographic)
            {
                parts.Add(string.Create(culture, $"Drawing {DrawnShapes:N0} shapes with no SRID, read as longitude and latitude."));
            }
            else
            {
                parts.Add(string.Create(culture, $"Drawing {DrawnShapes:N0} shapes."));
            }

            if (OtherSridRows > 0)
            {
                parts.Add(string.Create(culture, $"{OtherSridRows:N0} rows in other coordinate systems are not drawn."));
            }

            if (CappedRows is { } capped)
            {
                parts.Add(string.Create(culture, $"{capped:N0} rows are past the drawing limit."));
            }

            if (DroppedParts == 1)
            {
                parts.Add("1 part of a multi-part geometry cannot be drawn and is left out.");
            }
            else if (DroppedParts > 1)
            {
                parts.Add(string.Create(culture, $"{DroppedParts:N0} parts of multi-part geometries cannot be drawn and are left out."));
            }

            foreach (var (keyword, count) in _unsupportedTypes.OrderBy(p => p.Key, StringComparer.Ordinal))
            {
                parts.Add(string.Create(culture, $"{count:N0} rows use {keyword}, which cannot be drawn."));
            }

            if (UnreadableRows > 0)
            {
                parts.Add(string.Create(culture, $"{UnreadableRows:N0} rows could not be read."));
            }

            return string.Join(' ', parts);
        }
    }

    /// <summary>Why a result with a spatial source still drew nothing. Always names a reason, so the map is never blank.</summary>
    public string EmptyReason
    {
        get
        {
            if (ReadableRows == 0)
            {
                if (_unsupportedTypes.Count > 0)
                {
                    return $"This column holds {string.Join(", ", _unsupportedTypes.Keys.Order(StringComparer.Ordinal))}, which the map cannot draw.";
                }

                if (UnreadableRows > 0)
                {
                    return string.Create(CultureInfo.CurrentCulture,
                        $"{UnreadableRows:N0} values in this column are not in a format the map can read. The grid still shows them as the database returned them.");
                }

                return FromCoordinateColumns ? "Every latitude or longitude in these columns is null." : "Every geometry in this column is empty or null.";
            }

            if (Projectability.Kind == ProjectabilityKind.Unsupported)
            {
                return Projectability.Srid is { } srid
                    ? string.Create(CultureInfo.InvariantCulture,
                        $"The map cannot place SRID {srid}. It reads longitude and latitude, such as SRID 4326, and Web Mercator. Query ST_Transform(geom, 4326) to see these shapes.")
                    : "This column carries no SRID and its coordinates are outside the range of longitude and latitude, so the map cannot place them.";
            }

            return "Nothing in this column can be drawn. The coordinates are out of range for their coordinate system, or a line or ring has too few points.";
        }
    }
}

public sealed class ResultMapProjection
{
    public static readonly ResultMapProjection Empty = new([], new ResultMapDiagnostics());

    public ResultMapProjection(IReadOnlyList<ResultMapShape> shapes, ResultMapDiagnostics diagnostics)
    {
        Shapes = shapes;
        Diagnostics = diagnostics;
    }

    public IReadOnlyList<ResultMapShape> Shapes { get; }

    public ResultMapDiagnostics Diagnostics { get; }

    public bool IsEmpty => Shapes.Count == 0;
}

/// <summary>
/// Turns one map source of a loaded result into drawable shapes. The work grows with the page, which can be large, so
/// callers run it off the UI thread and pass a token that a newer result cancels.
/// </summary>
public static class ResultMapProjector
{
    /// <summary>The macOS budgets, which MapKit's aggregate overlays measured comfortable; a renderer may pass a smaller one.</summary>
    public const int MaximumShapes = 100_000;

    public const int MaximumVertices = 2_000_000;

    public static ShapeBudget DefaultBudget => new(MaximumShapes, MaximumVertices);

    /// <summary>Projects the rows <paramref name="rowOrder"/> names in display order, or every row when it is null.</summary>
    public static ResultMapProjection Project(
        ResultSet result,
        MapSource source,
        ShapeBudget? budget = null,
        IReadOnlyList<int>? rowOrder = null,
        CancellationToken cancellationToken = default)
    {
        ArgumentNullException.ThrowIfNull(result);
        ArgumentNullException.ThrowIfNull(source);
        var allowance = budget ?? DefaultBudget;
        return source.Kind == MapSourceKind.Coordinates
            ? ProjectCoordinates(result, source, allowance, rowOrder, cancellationToken)
            : ProjectGeometry(result, source, allowance, rowOrder, cancellationToken);
    }

    /// <summary>
    /// The SRID most of the column uses; a tie goes to a named SRID, since an explicit one is better evidence than an
    /// absent one. False when nothing was counted.
    /// </summary>
    public static bool TryGetMajoritySrid(IReadOnlyDictionary<int, int> counts, int unnamed, out int? srid)
    {
        ArgumentNullException.ThrowIfNull(counts);
        srid = null;
        var best = unnamed;
        var found = unnamed > 0;
        foreach (var (key, count) in counts)
        {
            if (count > best || (count == best && found && (srid is null || key > srid)) || !found)
            {
                best = count;
                srid = key;
                found = true;
            }
        }

        return found;
    }

    public static SpatialProjectability Projectability(IReadOnlyList<SpatialValue> values, int? srid)
    {
        ArgumentNullException.ThrowIfNull(values);
        if (srid is not null)
        {
            return SpatialProjection.Projectability(srid, EmptyGeometry.Instance);
        }

        // Decided over the whole drawable set: one stray coordinate is enough to mean the column is not degrees.
        foreach (var value in values)
        {
            if (!SpatialProjection.FitsGeographicEnvelope(value.Geometry))
            {
                return SpatialProjectability.Unsupported(null);
            }
        }

        return values.Count == 0 ? SpatialProjectability.Unsupported(null) : SpatialProjectability.AssumedGeographic;
    }

    private static ResultMapProjection ProjectGeometry(ResultSet result, MapSource source, ShapeBudget budget, IReadOnlyList<int>? rowOrder, CancellationToken ct)
    {
        var diagnostics = new ResultMapDiagnostics();
        var rows = result.Rows;
        var count = rowOrder?.Count ?? rows.Count;
        var values = new List<(int Row, SpatialValue Value)>();
        var sridCounts = new Dictionary<int, int>();
        var unnamed = 0;
        for (var i = 0; i < count; i++)
        {
            ct.ThrowIfCancellationRequested();
            var row = rowOrder?[i] ?? i;
            diagnostics.ConsideredRows++;
            var cells = rows[row];
            if (source.Column >= cells.Length || SpatialValueReader.ReadCell(cells[source.Column], source.SelfDescribingOnly) is not { } reading)
            {
                diagnostics.EmptyRows++;
                continue;
            }

            if (reading.Value is { } value)
            {
                if (value.Geometry.IsEmpty)
                {
                    diagnostics.EmptyRows++;
                    continue;
                }

                values.Add((row, value));
                if (value.Srid is { } srid)
                {
                    sridCounts[srid] = sridCounts.GetValueOrDefault(srid) + 1;
                }
                else
                {
                    unnamed++;
                }
            }
            else if (reading.Failure is { Kind: SpatialFailureKind.UnsupportedGeometryType, GeometryType: { } keyword })
            {
                diagnostics.CountUnsupported(keyword);
            }
            else
            {
                diagnostics.UnreadableRows++;
            }
        }

        diagnostics.ReadableRows = values.Count;
        if (!TryGetMajoritySrid(sridCounts, unnamed, out var majority))
        {
            return new ResultMapProjection([], diagnostics);
        }

        var drawable = new List<SpatialValue>(values.Count);
        var drawableRows = new List<int>(values.Count);
        foreach (var (row, value) in values)
        {
            if (value.Srid == majority)
            {
                drawable.Add(value);
                drawableRows.Add(row);
            }
        }

        diagnostics.OtherSridRows = values.Count - drawable.Count;
        diagnostics.DrawnSrid = majority;
        var projectability = Projectability(drawable, majority);
        diagnostics.Projectability = projectability;
        if (projectability.Kind == ProjectabilityKind.Unsupported)
        {
            return new ResultMapProjection([], diagnostics);
        }

        var shapes = new List<ResultMapShape>();
        var drawnRows = 0;
        var capped = 0;
        for (var i = 0; i < drawable.Count; i++)
        {
            ct.ThrowIfCancellationRequested();
            if (budget.IsExhausted)
            {
                capped++;
                continue;
            }

            var before = shapes.Count;
            var dropped = SpatialShapeBuilder.Append(drawable[i].Geometry, drawableRows[i], projectability, ref budget, shapes);

            // A row the budget cut short is counted as capped as well as drawn: part of it is on the map and the rest
            // is not, and saying nothing would be a silent truncation.
            if (budget.IsExhausted)
            {
                capped++;
            }

            if (shapes.Count == before)
            {
                if (!budget.IsExhausted)
                {
                    diagnostics.UnreadableRows++;
                }

                continue;
            }

            drawnRows++;
            diagnostics.DroppedParts += dropped;
        }

        diagnostics.DrawnShapes = shapes.Count;
        diagnostics.DrawnRows = drawnRows;
        diagnostics.CappedRows = capped > 0 ? capped : null;
        return new ResultMapProjection(shapes, diagnostics);
    }

    private static ResultMapProjection ProjectCoordinates(ResultSet result, MapSource source, ShapeBudget budget, IReadOnlyList<int>? rowOrder, CancellationToken ct)
    {
        var diagnostics = new ResultMapDiagnostics
        {
            FromCoordinateColumns = true,
            Projectability = SpatialProjectability.Geographic,
            DrawnSrid = 4326,
        };
        var rows = result.Rows;
        var count = rowOrder?.Count ?? rows.Count;
        var shapes = new List<ResultMapShape>();
        var capped = 0;
        for (var i = 0; i < count; i++)
        {
            ct.ThrowIfCancellationRequested();
            var row = rowOrder?[i] ?? i;
            diagnostics.ConsideredRows++;
            var cells = rows[row];
            var latitude = cells[source.Column];
            var longitude = cells[source.LongitudeColumn];
            if (latitude is null || longitude is null)
            {
                diagnostics.EmptyRows++;
                continue;
            }

            if (MapSourceDetector.ToCoordinate(latitude, longitude) is not { IsValid: true } coordinate)
            {
                diagnostics.UnreadableRows++;
                continue;
            }

            diagnostics.ReadableRows++;
            if (!budget.Take(1))
            {
                capped++;
                continue;
            }

            shapes.Add(new ResultMapShape(row, MapShapeKind.Point, [[coordinate]]));
        }

        diagnostics.DrawnShapes = shapes.Count;
        diagnostics.DrawnRows = shapes.Count;
        diagnostics.CappedRows = capped > 0 ? capped : null;
        return new ResultMapProjection(shapes, diagnostics);
    }
}

/// <summary>Builds the shapes of one geometry, spending the budget shape by shape since one row can hold any number.</summary>
internal static class SpatialShapeBuilder
{
    /// <summary>Appends the shapes and returns the members dropped for unplaceable coordinates or too few vertices.</summary>
    public static int Append(SpatialGeometry geometry, int row, SpatialProjectability projectability, ref ShapeBudget budget, List<ResultMapShape> output)
    {
        var dropped = 0;
        Append(geometry, row, projectability, 1, ref budget, output, ref dropped);
        return dropped;
    }

    private static void Append(SpatialGeometry geometry, int row, SpatialProjectability projectability, int depth, ref ShapeBudget budget, List<ResultMapShape> output, ref int dropped)
    {
        // The readers' bound, for the same reason: a collection nested past it is stack depth rather than geometry.
        if (depth > SpatialLimits.MaximumNestingDepth)
        {
            dropped++;
            return;
        }

        switch (geometry)
        {
            case PointGeometry point:
                if (SpatialProjection.Project(point.Point, projectability) is not { } coordinate)
                {
                    dropped++;
                }
                else if (budget.Take(1))
                {
                    output.Add(new ResultMapShape(row, MapShapeKind.Point, [[coordinate]]));
                }

                break;
            case MultiPointGeometry multi:
                foreach (var member in multi.Points)
                {
                    if (SpatialProjection.Project(member, projectability) is not { } placed)
                    {
                        dropped++;
                        continue;
                    }

                    if (!budget.Take(1))
                    {
                        return;
                    }

                    output.Add(new ResultMapShape(row, MapShapeKind.Point, [[placed]]));
                }

                break;
            case LineStringGeometry line:
                AppendLine(line.Points.AsSpan(), row, projectability, ref budget, output, ref dropped);
                break;
            case MultiLineStringGeometry lines:
                foreach (var member in lines.Lines)
                {
                    if (!AppendLine(member.AsSpan(), row, projectability, ref budget, output, ref dropped))
                    {
                        return;
                    }
                }

                break;
            case PolygonGeometry polygon:
                AppendPolygon(polygon.Rings, row, projectability, ref budget, output, ref dropped);
                break;
            case MultiPolygonGeometry polygons:
                foreach (var member in polygons.Polygons)
                {
                    if (!AppendPolygon(member, row, projectability, ref budget, output, ref dropped))
                    {
                        return;
                    }
                }

                break;
            case GeometryCollection collection:
                foreach (var child in collection.Geometries)
                {
                    if (budget.IsExhausted)
                    {
                        return;
                    }

                    Append(child, row, projectability, depth + 1, ref budget, output, ref dropped);
                }

                break;
        }
    }

    /// <summary>False only when the budget ran out, which stops the caller's loop.</summary>
    private static bool AppendLine(ReadOnlySpan<SpatialPoint> points, int row, SpatialProjectability projectability, ref ShapeBudget budget, List<ResultMapShape> output, ref int dropped)
    {
        if (points.IsEmpty)
        {
            return true;
        }

        if (Project(points, projectability) is not { Length: >= 2 } run)
        {
            dropped++;
            return true;
        }

        if (!budget.Take(run.Length))
        {
            return false;
        }

        output.Add(new ResultMapShape(row, MapShapeKind.Polyline, [run]));
        return true;
    }

    private static bool AppendPolygon(System.Collections.Immutable.ImmutableArray<System.Collections.Immutable.ImmutableArray<SpatialPoint>> rings, int row, SpatialProjectability projectability, ref ShapeBudget budget, List<ResultMapShape> output, ref int dropped)
    {
        if (rings.IsDefaultOrEmpty || rings[0].IsDefaultOrEmpty)
        {
            return true;
        }

        if (Project(rings[0].AsSpan(), projectability) is not { Length: >= 3 } exterior)
        {
            dropped++;
            return true;
        }

        var projected = new List<GeographicCoordinate[]>(rings.Length) { exterior };
        var vertices = exterior.Length;

        // A hole that cannot be placed is dropped and the polygon kept: losing a hole is a smaller lie than losing the row.
        for (var i = 1; i < rings.Length; i++)
        {
            if (Project(rings[i].AsSpan(), projectability) is { Length: >= 3 } hole)
            {
                projected.Add(hole);
                vertices += hole.Length;
            }
        }

        if (!budget.Take(vertices))
        {
            return false;
        }

        output.Add(new ResultMapShape(row, MapShapeKind.Polygon, [.. projected]));
        return true;
    }

    /// <summary>A run is dropped whole when any coordinate cannot be placed; the rest would draw an outline nobody stored.</summary>
    private static GeographicCoordinate[]? Project(ReadOnlySpan<SpatialPoint> points, SpatialProjectability projectability)
    {
        var output = new GeographicCoordinate[points.Length];
        for (var i = 0; i < points.Length; i++)
        {
            if (SpatialProjection.Project(points[i], projectability) is not { } coordinate)
            {
                return null;
            }

            output[i] = coordinate;
        }

        return output;
    }
}
