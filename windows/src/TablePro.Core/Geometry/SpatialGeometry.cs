using System.Collections.Immutable;

namespace TablePro.Core.Geometry;

/// <summary>One stored coordinate, in the units of the coordinate system its value names.</summary>
public readonly record struct SpatialPoint(double X, double Y);

/// <summary>
/// A geometry as the database describes it. Z and M ordinates are read so a parser stays in step with the wire format
/// and then dropped, because the map draws on a flat projection with nowhere to put them.
/// </summary>
public abstract record SpatialGeometry
{
    private protected SpatialGeometry()
    {
    }

    /// <summary>GeoJSON's spelling of the type, a technical term that is never translated.</summary>
    public abstract string TypeName { get; }

    public abstract bool IsEmpty { get; }

    public abstract int PointCount { get; }

    /// <summary>Calls <paramref name="visit"/> for every coordinate, so an extent or envelope test needs no list.</summary>
    public abstract void ForEachPoint(Action<SpatialPoint> visit);

    /// <summary>Whether every coordinate passes <paramref name="test"/>; stops at the first that fails.</summary>
    public abstract bool AllPoints(Func<SpatialPoint, bool> test);
}

public sealed record EmptyGeometry : SpatialGeometry
{
    public static readonly EmptyGeometry Instance = new();

    private EmptyGeometry()
    {
    }

    public override string TypeName => "Empty";

    public override bool IsEmpty => true;

    public override int PointCount => 0;

    public override void ForEachPoint(Action<SpatialPoint> visit)
    {
    }

    public override bool AllPoints(Func<SpatialPoint, bool> test) => true;
}

public sealed record PointGeometry(SpatialPoint Point) : SpatialGeometry
{
    public PointGeometry(double x, double y)
        : this(new SpatialPoint(x, y))
    {
    }

    public override string TypeName => "Point";

    public override bool IsEmpty => false;

    public override int PointCount => 1;

    public override void ForEachPoint(Action<SpatialPoint> visit) => visit(Point);

    public override bool AllPoints(Func<SpatialPoint, bool> test) => test(Point);
}

public sealed record LineStringGeometry(ImmutableArray<SpatialPoint> Points) : SpatialGeometry
{
    public override string TypeName => "LineString";

    public override bool IsEmpty => Points.IsDefaultOrEmpty;

    public override int PointCount => Points.Length;

    public override void ForEachPoint(Action<SpatialPoint> visit) => GeometryRuns.Visit(Points, visit);

    public override bool AllPoints(Func<SpatialPoint, bool> test) => GeometryRuns.All(Points, test);

    public bool Equals(LineStringGeometry? other) => other is not null && GeometryRuns.Equal(Points, other.Points);

    public override int GetHashCode() => GeometryRuns.Hash(Points);
}

/// <summary>The first ring is the exterior; every later ring is a hole.</summary>
public sealed record PolygonGeometry(ImmutableArray<ImmutableArray<SpatialPoint>> Rings) : SpatialGeometry
{
    public override string TypeName => "Polygon";

    public override bool IsEmpty => GeometryRuns.AllEmpty(Rings);

    public override int PointCount => GeometryRuns.Count(Rings);

    public override void ForEachPoint(Action<SpatialPoint> visit) => GeometryRuns.Visit(Rings, visit);

    public override bool AllPoints(Func<SpatialPoint, bool> test) => GeometryRuns.All(Rings, test);

    public bool Equals(PolygonGeometry? other) => other is not null && GeometryRuns.Equal(Rings, other.Rings);

    public override int GetHashCode() => Rings.Length;
}

public sealed record MultiPointGeometry(ImmutableArray<SpatialPoint> Points) : SpatialGeometry
{
    public override string TypeName => "MultiPoint";

    public override bool IsEmpty => Points.IsDefaultOrEmpty;

    public override int PointCount => Points.Length;

    public override void ForEachPoint(Action<SpatialPoint> visit) => GeometryRuns.Visit(Points, visit);

    public override bool AllPoints(Func<SpatialPoint, bool> test) => GeometryRuns.All(Points, test);

    public bool Equals(MultiPointGeometry? other) => other is not null && GeometryRuns.Equal(Points, other.Points);

    public override int GetHashCode() => GeometryRuns.Hash(Points);
}

public sealed record MultiLineStringGeometry(ImmutableArray<ImmutableArray<SpatialPoint>> Lines) : SpatialGeometry
{
    public override string TypeName => "MultiLineString";

    public override bool IsEmpty => GeometryRuns.AllEmpty(Lines);

    public override int PointCount => GeometryRuns.Count(Lines);

    public override void ForEachPoint(Action<SpatialPoint> visit) => GeometryRuns.Visit(Lines, visit);

    public override bool AllPoints(Func<SpatialPoint, bool> test) => GeometryRuns.All(Lines, test);

    public bool Equals(MultiLineStringGeometry? other) => other is not null && GeometryRuns.Equal(Lines, other.Lines);

    public override int GetHashCode() => Lines.Length;
}

public sealed record MultiPolygonGeometry(ImmutableArray<ImmutableArray<ImmutableArray<SpatialPoint>>> Polygons) : SpatialGeometry
{
    public override string TypeName => "MultiPolygon";

    public override bool IsEmpty
    {
        get
        {
            foreach (var polygon in Polygons)
            {
                if (!GeometryRuns.AllEmpty(polygon))
                {
                    return false;
                }
            }

            return true;
        }
    }

    public override int PointCount
    {
        get
        {
            var count = 0;
            foreach (var polygon in Polygons)
            {
                count += GeometryRuns.Count(polygon);
            }

            return count;
        }
    }

    public override void ForEachPoint(Action<SpatialPoint> visit)
    {
        foreach (var polygon in Polygons)
        {
            GeometryRuns.Visit(polygon, visit);
        }
    }

    public override bool AllPoints(Func<SpatialPoint, bool> test)
    {
        foreach (var polygon in Polygons)
        {
            if (!GeometryRuns.All(polygon, test))
            {
                return false;
            }
        }

        return true;
    }

    public bool Equals(MultiPolygonGeometry? other)
    {
        if (other is null || other.Polygons.Length != Polygons.Length)
        {
            return false;
        }

        for (var i = 0; i < Polygons.Length; i++)
        {
            if (!GeometryRuns.Equal(Polygons[i], other.Polygons[i]))
            {
                return false;
            }
        }

        return true;
    }

    public override int GetHashCode() => Polygons.Length;
}

public sealed record GeometryCollection(ImmutableArray<SpatialGeometry> Geometries) : SpatialGeometry
{
    public override string TypeName => "GeometryCollection";

    public override bool IsEmpty
    {
        get
        {
            foreach (var child in Geometries)
            {
                if (!child.IsEmpty)
                {
                    return false;
                }
            }

            return true;
        }
    }

    public override int PointCount
    {
        get
        {
            var count = 0;
            foreach (var child in Geometries)
            {
                count += child.PointCount;
            }

            return count;
        }
    }

    public override void ForEachPoint(Action<SpatialPoint> visit)
    {
        foreach (var child in Geometries)
        {
            child.ForEachPoint(visit);
        }
    }

    public override bool AllPoints(Func<SpatialPoint, bool> test)
    {
        foreach (var child in Geometries)
        {
            if (!child.AllPoints(test))
            {
                return false;
            }
        }

        return true;
    }

    public bool Equals(GeometryCollection? other) =>
        other is not null && Geometries.AsSpan().SequenceEqual(other.Geometries.AsSpan());

    public override int GetHashCode() => Geometries.Length;
}

/// <summary>
/// What the engine handed over, with the coordinate system it named. <see cref="Srid"/> is null when the value carried
/// none, which is not the same as zero: PostGIS writes no prefix for 0 and MySQL writes a literal 0, and both mean
/// "unknown" rather than a system numbered zero.
/// </summary>
public sealed record SpatialValue(int? Srid, SpatialGeometry Geometry);

public enum SpatialFailureKind
{
    NotGeometry,

    /// <summary>A type the readers recognize but no parsing turns into line segments, such as CIRCULARSTRING.</summary>
    UnsupportedGeometryType,

    Malformed,
}

/// <summary>
/// Why a cell could not be read as a geometry. An unsupported type carries its keyword so the map can name it: told
/// "CIRCULARSTRING cannot be drawn" a reader knows what to do, told "3 shapes could not be drawn" they learn nothing.
/// </summary>
public readonly record struct SpatialReadFailure(SpatialFailureKind Kind, string? GeometryType = null)
{
    public static SpatialReadFailure NotGeometry => new(SpatialFailureKind.NotGeometry);

    public static SpatialReadFailure Malformed => new(SpatialFailureKind.Malformed);

    public static SpatialReadFailure Unsupported(string geometryType) => new(SpatialFailureKind.UnsupportedGeometryType, geometryType);
}

/// <summary>Either a value or the reason there is none.</summary>
public readonly record struct SpatialReading
{
    private SpatialReading(SpatialValue? value, SpatialReadFailure failure)
    {
        Value = value;
        Failure = failure;
    }

    public SpatialValue? Value { get; }

    /// <summary>Meaningful only when <see cref="Succeeded"/> is false.</summary>
    public SpatialReadFailure Failure { get; }

    public bool Succeeded => Value is not null;

    public static SpatialReading Success(SpatialValue value) => new(value, default);

    public static SpatialReading Fail(SpatialReadFailure failure) => new(null, failure);

    public static implicit operator SpatialReading(SpatialValue value) => Success(value);

    public static implicit operator SpatialReading(SpatialReadFailure failure) => Fail(failure);

    public override string ToString() => Value is { } value ? $"Success({value})" : $"Failure({Failure})";
}

/// <summary>Bounds every reader shares, so one crafted value cannot cost more than a page of rows does.</summary>
public static class SpatialLimits
{
    /// <summary>
    /// How deeply a geometry collection may nest. Each level is one more frame on a reader's stack and the wire formats
    /// put no limit on it, so a few hundred bytes of collection headers would exhaust the stack rather than fail.
    /// Databases write at most two.
    /// </summary>
    public const int MaximumNestingDepth = 32;
}

/// <summary>The loops every run-shaped geometry shares, written once so the records stay declarative.</summary>
internal static class GeometryRuns
{
    public static void Visit(ImmutableArray<SpatialPoint> run, Action<SpatialPoint> visit)
    {
        foreach (var point in run)
        {
            visit(point);
        }
    }

    public static void Visit(ImmutableArray<ImmutableArray<SpatialPoint>> runs, Action<SpatialPoint> visit)
    {
        foreach (var run in runs)
        {
            Visit(run, visit);
        }
    }

    public static bool All(ImmutableArray<SpatialPoint> run, Func<SpatialPoint, bool> test)
    {
        foreach (var point in run)
        {
            if (!test(point))
            {
                return false;
            }
        }

        return true;
    }

    public static bool All(ImmutableArray<ImmutableArray<SpatialPoint>> runs, Func<SpatialPoint, bool> test)
    {
        foreach (var run in runs)
        {
            if (!All(run, test))
            {
                return false;
            }
        }

        return true;
    }

    public static bool AllEmpty(ImmutableArray<ImmutableArray<SpatialPoint>> runs)
    {
        foreach (var run in runs)
        {
            if (!run.IsDefaultOrEmpty)
            {
                return false;
            }
        }

        return true;
    }

    public static int Count(ImmutableArray<ImmutableArray<SpatialPoint>> runs)
    {
        var count = 0;
        foreach (var run in runs)
        {
            count += run.Length;
        }

        return count;
    }

    public static bool Equal(ImmutableArray<SpatialPoint> left, ImmutableArray<SpatialPoint> right) =>
        left.AsSpan().SequenceEqual(right.AsSpan());

    public static bool Equal(ImmutableArray<ImmutableArray<SpatialPoint>> left, ImmutableArray<ImmutableArray<SpatialPoint>> right)
    {
        if (left.Length != right.Length)
        {
            return false;
        }

        for (var i = 0; i < left.Length; i++)
        {
            if (!Equal(left[i], right[i]))
            {
                return false;
            }
        }

        return true;
    }

    public static int Hash(ImmutableArray<SpatialPoint> run) =>
        run.IsDefaultOrEmpty ? 0 : HashCode.Combine(run.Length, run[0]);
}
