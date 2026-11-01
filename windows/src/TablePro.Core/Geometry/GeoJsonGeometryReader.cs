using System.Collections.Immutable;
using System.Text.Json;

namespace TablePro.Core.Geometry;

/// <summary>
/// Reads the GeoJSON MongoDB, Snowflake and Elasticsearch hand over. RFC 7946 fixes coordinates as longitude then
/// latitude and the system as WGS84, so a value reports SRID 4326; a third position is altitude and is dropped. Each cell
/// is read on its own, so one bad coordinate costs its row and not the whole result.
/// </summary>
public static class GeoJsonGeometryReader
{
    // Each collection level is an object and an array; the bound sits past the deepest value the shared limit accepts so
    // the limit, not the parser, decides, while a document of thousands of levels still stops in the parser.
    private static readonly JsonDocumentOptions Options = new() { MaxDepth = (SpatialLimits.MaximumNestingDepth * 3) + 8 };

    public static SpatialReading Read(string text)
    {
        ArgumentNullException.ThrowIfNull(text);
        try
        {
            using var document = JsonDocument.Parse(text, Options);
            if (document.RootElement.ValueKind != JsonValueKind.Object || Geometry(document.RootElement, 1) is not { } geometry)
            {
                return SpatialReadFailure.NotGeometry;
            }

            return new SpatialValue(4326, geometry);
        }
        catch (JsonException)
        {
            return SpatialReadFailure.NotGeometry;
        }
    }

    public static bool LooksLikeGeoJson(ReadOnlySpan<char> text)
    {
        text = text.TrimStart();
        if (text.IsEmpty || text[0] != '{' || !text.Contains("\"type\"", StringComparison.Ordinal))
        {
            return false;
        }

        return text.Contains("\"coordinates\"", StringComparison.Ordinal) || text.Contains("\"geometry\"", StringComparison.Ordinal)
            || text.Contains("\"geometries\"", StringComparison.Ordinal) || text.Contains("\"features\"", StringComparison.Ordinal);
    }

    private static SpatialGeometry? Geometry(JsonElement element, int depth)
    {
        if (depth > SpatialLimits.MaximumNestingDepth || element.ValueKind != JsonValueKind.Object
            || !element.TryGetProperty("type", out var typeElement) || typeElement.ValueKind != JsonValueKind.String)
        {
            return null;
        }

        // RFC 7946 fixes the capitalisation, but Elasticsearch documents geo_shape types in lowercase and returns a
        // document as it was indexed.
        var type = typeElement.GetString()!.ToUpperInvariant();
        element.TryGetProperty("coordinates", out var coordinates);
        switch (type)
        {
            case "FEATURE":
                return element.TryGetProperty("geometry", out var nested) ? Geometry(nested, depth + 1) : null;
            case "FEATURECOLLECTION":
            {
                if (!element.TryGetProperty("features", out var features) || features.ValueKind != JsonValueKind.Array)
                {
                    return null;
                }

                var children = ImmutableArray.CreateBuilder<SpatialGeometry>();
                foreach (var feature in features.EnumerateArray())
                {
                    if (Geometry(feature, depth + 1) is { } child)
                    {
                        children.Add(child);
                    }
                }

                return children.Count == 1 ? children[0] : new GeometryCollection(children.DrainToImmutable());
            }

            case "GEOMETRYCOLLECTION":
            {
                if (!element.TryGetProperty("geometries", out var members) || members.ValueKind != JsonValueKind.Array)
                {
                    return null;
                }

                var children = ImmutableArray.CreateBuilder<SpatialGeometry>();
                foreach (var member in members.EnumerateArray())
                {
                    if (Geometry(member, depth + 1) is { } child)
                    {
                        children.Add(child);
                    }
                }

                return new GeometryCollection(children.DrainToImmutable());
            }

            case "POINT":
                return Position(coordinates) is { } point ? new PointGeometry(point) : null;
            case "MULTIPOINT":
                return Positions(coordinates) is { } points ? new MultiPointGeometry(points) : null;
            case "LINESTRING":
                return Positions(coordinates) is { } line ? new LineStringGeometry(line) : null;
            case "MULTILINESTRING":
                return Rings(coordinates) is { } lines ? new MultiLineStringGeometry(lines) : null;
            case "POLYGON":
                return Rings(coordinates) is { } rings ? new PolygonGeometry(rings) : null;
            case "MULTIPOLYGON":
            {
                if (coordinates.ValueKind != JsonValueKind.Array)
                {
                    return null;
                }

                var polygons = ImmutableArray.CreateBuilder<ImmutableArray<ImmutableArray<SpatialPoint>>>(coordinates.GetArrayLength());
                foreach (var entry in coordinates.EnumerateArray())
                {
                    if (Rings(entry) is not { } polygon)
                    {
                        return null;
                    }

                    polygons.Add(polygon);
                }

                return new MultiPolygonGeometry(polygons.MoveToImmutable());
            }

            default:
                return null;
        }
    }

    private static SpatialPoint? Position(JsonElement element)
    {
        if (element.ValueKind != JsonValueKind.Array || element.GetArrayLength() < 2)
        {
            return null;
        }

        var x = element[0];
        var y = element[1];
        return x.ValueKind == JsonValueKind.Number && y.ValueKind == JsonValueKind.Number ? new SpatialPoint(x.GetDouble(), y.GetDouble()) : null;
    }

    private static ImmutableArray<SpatialPoint>? Positions(JsonElement element)
    {
        if (element.ValueKind != JsonValueKind.Array)
        {
            return null;
        }

        var points = ImmutableArray.CreateBuilder<SpatialPoint>(element.GetArrayLength());
        foreach (var entry in element.EnumerateArray())
        {
            if (Position(entry) is not { } point)
            {
                return null;
            }

            points.Add(point);
        }

        return points.MoveToImmutable();
    }

    private static ImmutableArray<ImmutableArray<SpatialPoint>>? Rings(JsonElement element)
    {
        if (element.ValueKind != JsonValueKind.Array)
        {
            return null;
        }

        var rings = ImmutableArray.CreateBuilder<ImmutableArray<SpatialPoint>>(element.GetArrayLength());
        foreach (var entry in element.EnumerateArray())
        {
            if (Positions(entry) is not { } ring)
            {
                return null;
            }

            rings.Add(ring);
        }

        return rings.MoveToImmutable();
    }
}
