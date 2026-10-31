using System.Collections.Frozen;

namespace TablePro.Core.Geometry;

/// <summary>A longitude and latitude in WGS84 degrees, which is the only thing the map draws.</summary>
public readonly record struct GeographicCoordinate(double Longitude, double Latitude)
{
    /// <summary>Checked before a shape is built, since one coordinate out of range would wreck the fitted extent.</summary>
    public bool IsValid => double.IsFinite(Longitude) && double.IsFinite(Latitude)
        && Longitude is >= -180 and <= 180 && Latitude is >= -90 and <= 90;
}

public enum ProjectabilityKind
{
    /// <summary>Already longitude and latitude in degrees.</summary>
    Geographic,

    /// <summary>Spherical Mercator metres, inverted by a closed-form formula.</summary>
    WebMercator,

    /// <summary>No SRID was carried and every value fits the degree envelope, so they are drawn as degrees, and said so.</summary>
    AssumedGeographic,

    /// <summary>A projected or unknown system that cannot be turned into degrees here.</summary>
    Unsupported,
}

/// <summary>How, or whether, a coordinate system's values can reach the map.</summary>
public readonly record struct SpatialProjectability(ProjectabilityKind Kind, int? Srid = null)
{
    public static SpatialProjectability Geographic => new(ProjectabilityKind.Geographic);

    public static SpatialProjectability WebMercator => new(ProjectabilityKind.WebMercator);

    public static SpatialProjectability AssumedGeographic => new(ProjectabilityKind.AssumedGeographic);

    public static SpatialProjectability Unsupported(int? srid) => new(ProjectabilityKind.Unsupported, srid);
}

public static class SpatialProjection
{
    private const double EarthRadius = 6_378_137.0;

    /// <summary>
    /// Geographic systems drawn as WGS84 with no datum shift: each sits within a few metres of it, far below what the map
    /// shows at the zoom a result is fitted to. 4979 is WGS84 in three dimensions.
    /// </summary>
    public static readonly FrozenSet<int> GeographicSrids = FrozenSet.Create(4326, 4269, 4979, 4258, 4283, 7844, 4490, 4674, 6318, 6668);

    /// <summary>The spherical Mercator codes: 3857, Google's 900913, Esri's 102100 and 102113, and the deprecated 3785.</summary>
    public static readonly FrozenSet<int> WebMercatorSrids = FrozenSet.Create(3857, 900913, 102100, 102113, 3785);

    public static SpatialProjectability Projectability(int? srid, SpatialGeometry geometry)
    {
        ArgumentNullException.ThrowIfNull(geometry);
        if (srid is { } known)
        {
            return GeographicSrids.Contains(known) ? SpatialProjectability.Geographic
                : WebMercatorSrids.Contains(known) ? SpatialProjectability.WebMercator
                : SpatialProjectability.Unsupported(known);
        }

        // PostGIS writes no prefix for SRID 0 and MySQL stores a literal 0, both meaning nobody said. Degrees are by far
        // the common case for such a column, so the values decide, and the map says it assumed.
        return FitsGeographicEnvelope(geometry) ? SpatialProjectability.AssumedGeographic : SpatialProjectability.Unsupported(null);
    }

    public static bool FitsGeographicEnvelope(SpatialGeometry geometry)
    {
        ArgumentNullException.ThrowIfNull(geometry);
        return geometry.PointCount > 0 && geometry.AllPoints(static p =>
            double.IsFinite(p.X) && double.IsFinite(p.Y) && p.X is >= -180 and <= 180 && p.Y is >= -90 and <= 90);
    }

    /// <summary>
    /// One stored coordinate in degrees, or null when it cannot be drawn. Stored order is longitude then latitude for
    /// every dialect read, MySQL included, whose WKB is longitude first even where its WKT prints latitude first.
    /// </summary>
    public static GeographicCoordinate? Project(SpatialPoint point, SpatialProjectability projectability)
    {
        GeographicCoordinate coordinate;
        switch (projectability.Kind)
        {
            case ProjectabilityKind.Geographic or ProjectabilityKind.AssumedGeographic:
                coordinate = new GeographicCoordinate(point.X, point.Y);
                break;
            case ProjectabilityKind.WebMercator:
                if (!double.IsFinite(point.X) || !double.IsFinite(point.Y))
                {
                    return null;
                }

                coordinate = new GeographicCoordinate(
                    point.X / EarthRadius * 180 / Math.PI,
                    ((2 * Math.Atan(Math.Exp(point.Y / EarthRadius))) - (Math.PI / 2)) * 180 / Math.PI);
                break;
            default:
                return null;
        }

        return coordinate.IsValid ? coordinate : null;
    }
}
