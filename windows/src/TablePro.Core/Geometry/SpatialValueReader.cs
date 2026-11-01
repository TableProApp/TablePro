using System.Collections.Immutable;
using System.Globalization;
using System.Text.Json;

namespace TablePro.Core.Geometry;

/// <summary>
/// Chooses a reader for one cell. There is no single wire format and the declared type does not settle it: a PostGIS
/// column reports <c>geometry</c> whether the value arrived as EWKT or as raw EWKB hex. So the value is sniffed, ordered
/// by how exclusive each shape is: hex digits only, then a leading brace, then a geometry keyword.
/// </summary>
public static class SpatialValueReader
{
    private const string GeohashAlphabet = "0123456789bcdefghjkmnpqrstuvwxyz";

    /// <summary>
    /// Every spelling an engine is known to use, including ClickHouse tuples and Elasticsearch's geo_point forms, for a
    /// column the engine itself declares spatial.
    /// </summary>
    public static SpatialReading Read(string text)
    {
        ArgumentNullException.ThrowIfNull(text);
        var trimmed = text.AsSpan().Trim();
        if (trimmed.IsEmpty)
        {
            return SpatialReadFailure.NotGeometry;
        }

        if (WkbGeometryReader.LooksLikeHex(trimmed))
        {
            return WkbGeometryReader.ReadHex(trimmed);
        }

        var value = trimmed.Length == text.Length ? text : trimmed.ToString();
        if (GeoJsonGeometryReader.LooksLikeGeoJson(trimmed))
        {
            return GeoJsonGeometryReader.Read(value);
        }

        if (WktGeometryReader.LooksLikeWkt(trimmed))
        {
            return WktGeometryReader.Read(value);
        }

        if (ReadClickHouseTuple(value) is { } tuple)
        {
            return tuple;
        }

        if (ReadElasticsearchGeoPoint(value) is { } geoPoint)
        {
            return geoPoint;
        }

        // A keyword the readers refuse still deserves its name in the message, so WKT gets the last word.
        return WktGeometryReader.Read(value);
    }

    /// <summary>
    /// Only the self-describing spellings (WKB hex, GeoJSON, WKT), for a column whose type says nothing about geometry. A
    /// geohash or a "lat,lon" string is too easily an ordinary word or pair of numbers to be believed there.
    /// </summary>
    public static SpatialReading ReadSelfDescribing(string text)
    {
        ArgumentNullException.ThrowIfNull(text);
        var trimmed = text.AsSpan().Trim();
        if (WkbGeometryReader.LooksLikeHex(trimmed))
        {
            return WkbGeometryReader.ReadHex(trimmed);
        }

        var value = trimmed.Length == text.Length ? text : trimmed.ToString();
        if (GeoJsonGeometryReader.LooksLikeGeoJson(trimmed))
        {
            return GeoJsonGeometryReader.Read(value);
        }

        // Only text opening with a word can be WKT, and a refused curve keeps its name for the map's message.
        if (trimmed.IsEmpty || !char.IsAsciiLetter(trimmed[0]))
        {
            return SpatialReadFailure.NotGeometry;
        }

        var wkt = WktGeometryReader.Read(value);
        return wkt.Succeeded || wkt.Failure.Kind == SpatialFailureKind.UnsupportedGeometryType ? wkt : SpatialReadFailure.NotGeometry;
    }

    /// <summary>
    /// What a cell holds: null for NULL and for an empty value, which say nothing about the column. Bytes are WKB in one
    /// of its containers and never go through the text readers, since the hex of a short blob is a valid geohash.
    /// </summary>
    public static SpatialReading? ReadCell(object? cell, bool selfDescribingOnly = false) => cell switch
    {
        byte[] { Length: > 0 } bytes => WkbGeometryReader.ReadAny(bytes),
        ReadOnlyMemory<byte> { IsEmpty: false } memory => WkbGeometryReader.ReadAny(memory.Span),
        string { Length: > 0 } text => selfDescribingOnly ? ReadSelfDescribing(text) : Read(text),
        _ => default(SpatialReading?),
    };

    /// <summary>
    /// ClickHouse streams tab-separated text, so a Point arrives as <c>(-122.4,37.7)</c> and a Ring or Polygon as tuples
    /// in arrays: a Tuple is written in parentheses and an Array in brackets, and both are accepted at every level.
    /// </summary>
    public static SpatialValue? ReadClickHouseTuple(string text)
    {
        ArgumentNullException.ThrowIfNull(text);
        var span = text.AsSpan();
        if (span.IsEmpty || span[0] is not ('(' or '[') || span[^1] is not (')' or ']'))
        {
            return null;
        }

        var index = 0;
        var node = TupleNode.Parse(span, ref index, depth: 1);
        if (node is null)
        {
            return null;
        }

        TupleNode.SkipWhitespace(span, ref index);
        return index == span.Length && node.ToGeometry() is { } geometry ? new SpatialValue(null, geometry) : null;
    }

    /// <summary>
    /// Elasticsearch's geo_point beyond WKT and GeoJSON. The axis order is the trap: the "lat,lon" string and the
    /// {"lat","lon"} object are latitude first, while the [lon, lat] array is longitude first like GeoJSON.
    /// </summary>
    public static SpatialValue? ReadElasticsearchGeoPoint(string text)
    {
        ArgumentNullException.ThrowIfNull(text);
        var point = ObjectForm(text) ?? ArrayForm(text) ?? StringForm(text) ?? GeohashForm(text);
        return point is { } p ? new SpatialValue(4326, new PointGeometry(p)) : null;
    }

    private static SpatialPoint? ValidPoint(double longitude, double latitude) =>
        double.IsFinite(longitude) && double.IsFinite(latitude) && latitude is >= -90 and <= 90 && longitude is >= -180 and <= 180
            ? new SpatialPoint(longitude, latitude)
            : null;

    private static SpatialPoint? ObjectForm(string text)
    {
        if (!text.StartsWith('{'))
        {
            return null;
        }

        try
        {
            using var document = JsonDocument.Parse(text);
            var root = document.RootElement;
            if (root.ValueKind != JsonValueKind.Object || !root.TryGetProperty("lat", out var lat) || lat.ValueKind != JsonValueKind.Number)
            {
                return null;
            }

            if ((root.TryGetProperty("lon", out var lon) || root.TryGetProperty("long", out lon)) && lon.ValueKind == JsonValueKind.Number)
            {
                return ValidPoint(lon.GetDouble(), lat.GetDouble());
            }

            return null;
        }
        catch (JsonException)
        {
            return null;
        }
    }

    private static SpatialPoint? ArrayForm(string text)
    {
        if (!text.StartsWith('['))
        {
            return null;
        }

        try
        {
            using var document = JsonDocument.Parse(text);
            var root = document.RootElement;
            if (root.ValueKind != JsonValueKind.Array || root.GetArrayLength() != 2
                || root[0].ValueKind != JsonValueKind.Number || root[1].ValueKind != JsonValueKind.Number)
            {
                return null;
            }

            return ValidPoint(root[0].GetDouble(), root[1].GetDouble());
        }
        catch (JsonException)
        {
            return null;
        }
    }

    private static SpatialPoint? StringForm(string text)
    {
        var span = text.AsSpan();
        var comma = span.IndexOf(',');
        if (comma < 0 || span[(comma + 1)..].Contains(','))
        {
            return null;
        }

        return double.TryParse(span[..comma].Trim(), NumberStyles.Float, CultureInfo.InvariantCulture, out var latitude)
            && double.TryParse(span[(comma + 1)..].Trim(), NumberStyles.Float, CultureInfo.InvariantCulture, out var longitude)
            ? ValidPoint(longitude, latitude)
            : null;
    }

    /// <summary>Base-32 bits interleaved from longitude; the centre of the cell is the point, as Elasticsearch resolves it.</summary>
    private static SpatialPoint? GeohashForm(string text)
    {
        if (text.Length is 0 or > 12)
        {
            return null;
        }

        double lonMin = -180, lonMax = 180, latMin = -90, latMax = 90;
        var evenBit = true;
        foreach (var character in text)
        {
            var value = GeohashAlphabet.IndexOf(char.ToLowerInvariant(character), StringComparison.Ordinal);
            if (value < 0)
            {
                return null;
            }

            for (var shift = 4; shift >= 0; shift--)
            {
                var bit = (value >> shift) & 1;
                if (evenBit)
                {
                    var mid = (lonMin + lonMax) / 2;
                    if (bit == 1)
                    {
                        lonMin = mid;
                    }
                    else
                    {
                        lonMax = mid;
                    }
                }
                else
                {
                    var mid = (latMin + latMax) / 2;
                    if (bit == 1)
                    {
                        latMin = mid;
                    }
                    else
                    {
                        latMax = mid;
                    }
                }

                evenBit = !evenBit;
            }
        }

        return ValidPoint((lonMin + lonMax) / 2, (latMin + latMax) / 2);
    }

    /// <summary>A bracketed tree of numbers, which is all a ClickHouse geo type is on the wire.</summary>
    private sealed class TupleNode
    {
        private TupleNode(double number) => Number = number;

        private TupleNode(List<TupleNode> children) => Children = children;

        private double Number { get; }

        private List<TupleNode>? Children { get; }

        public static void SkipWhitespace(ReadOnlySpan<char> text, ref int index)
        {
            while (index < text.Length && text[index] is ' ' or '\t')
            {
                index++;
            }
        }

        public static TupleNode? Parse(ReadOnlySpan<char> text, ref int index, int depth)
        {
            // Each bracket is one more frame and the wire puts no limit on them; a MultiPolygon, the deepest real value,
            // uses five.
            if (depth > SpatialLimits.MaximumNestingDepth)
            {
                return null;
            }

            SkipWhitespace(text, ref index);
            if (index >= text.Length)
            {
                return null;
            }

            if (text[index] is '(' or '[')
            {
                var closer = text[index] == '(' ? ')' : ']';
                index++;
                var children = new List<TupleNode>();
                SkipWhitespace(text, ref index);
                if (index < text.Length && text[index] == closer)
                {
                    index++;
                    return new TupleNode(children);
                }

                while (true)
                {
                    if (Parse(text, ref index, depth + 1) is not { } child)
                    {
                        return null;
                    }

                    children.Add(child);
                    SkipWhitespace(text, ref index);
                    if (index >= text.Length)
                    {
                        return null;
                    }

                    if (text[index] == ',')
                    {
                        index++;
                        continue;
                    }

                    if (text[index] == closer)
                    {
                        index++;
                        return new TupleNode(children);
                    }

                    return null;
                }
            }

            var start = index;
            while (index < text.Length && text[index] is not (',' or ')' or ']'))
            {
                index++;
            }

            return double.TryParse(text[start..index].Trim(), NumberStyles.Float, CultureInfo.InvariantCulture, out var value)
                ? new TupleNode(value)
                : null;
        }

        /// <summary>Shape decides the type: a pair is a Point, pairs a Ring, rings a Polygon, polygons a MultiPolygon.</summary>
        public SpatialGeometry? ToGeometry()
        {
            if (AsPoint() is { } point)
            {
                return new PointGeometry(point);
            }

            if (AsRing() is { } ring)
            {
                return new PolygonGeometry([ring]);
            }

            if (AsPolygon() is { } polygon)
            {
                return new PolygonGeometry(polygon);
            }

            if (Children is not { Count: > 0 } children)
            {
                return null;
            }

            var polygons = ImmutableArray.CreateBuilder<ImmutableArray<ImmutableArray<SpatialPoint>>>(children.Count);
            foreach (var child in children)
            {
                if (child.AsPolygon() is not { } member)
                {
                    return null;
                }

                polygons.Add(member);
            }

            return new MultiPolygonGeometry(polygons.MoveToImmutable());
        }

        private SpatialPoint? AsPoint() =>
            Children is [{ Children: null } x, { Children: null } y] ? new SpatialPoint(x.Number, y.Number) : null;

        private ImmutableArray<SpatialPoint>? AsRing()
        {
            if (Children is not { Count: > 0 } children)
            {
                return null;
            }

            var points = ImmutableArray.CreateBuilder<SpatialPoint>(children.Count);
            foreach (var child in children)
            {
                if (child.AsPoint() is not { } point)
                {
                    return null;
                }

                points.Add(point);
            }

            return points.MoveToImmutable();
        }

        private ImmutableArray<ImmutableArray<SpatialPoint>>? AsPolygon()
        {
            if (Children is not { Count: > 0 } children)
            {
                return null;
            }

            var rings = ImmutableArray.CreateBuilder<ImmutableArray<SpatialPoint>>(children.Count);
            foreach (var child in children)
            {
                if (child.AsRing() is not { } ring)
                {
                    return null;
                }

                rings.Add(ring);
            }

            return rings.MoveToImmutable();
        }
    }
}
