using System.Globalization;
using System.Numerics;
using TablePro.Core.Results;

namespace TablePro.Core.Geometry;

public enum MapSourceKind
{
    /// <summary>One column holding a geometry per row.</summary>
    Geometry,

    /// <summary>A latitude column and a longitude column, drawn as a point per row.</summary>
    Coordinates,
}

/// <summary>What the map can draw from a result: a geometry column, or a pair of latitude and longitude columns.</summary>
public sealed record MapSource
{
    private MapSource(MapSourceKind kind, string displayName, int column, int longitudeColumn, bool selfDescribingOnly)
    {
        Kind = kind;
        DisplayName = displayName;
        Column = column;
        LongitudeColumn = longitudeColumn;
        SelfDescribingOnly = selfDescribingOnly;
    }

    public MapSourceKind Kind { get; }

    /// <summary>Also the key a picked source is found again by after a re-run, which may reorder the SELECT list.</summary>
    public string DisplayName { get; }

    /// <summary>The geometry column, or the latitude column of a pair.</summary>
    public int Column { get; }

    /// <summary>The longitude column of a pair; -1 for a geometry column.</summary>
    public int LongitudeColumn { get; }

    /// <summary>
    /// True for a column whose type says nothing about geometry: only WKB, GeoJSON and WKT are believed there, since a
    /// geohash or a "lat,lon" string is too easily ordinary text.
    /// </summary>
    public bool SelfDescribingOnly { get; }

    public static MapSource ForGeometry(int column, string displayName, bool selfDescribingOnly = false) =>
        new(MapSourceKind.Geometry, displayName, column, -1, selfDescribingOnly);

    public static MapSource ForCoordinates(int latitudeColumn, int longitudeColumn, string displayName) =>
        new(MapSourceKind.Coordinates, displayName, latitudeColumn, longitudeColumn, false);
}

/// <summary>
/// Finds the columns a map can draw, decided once per column from its declared type and a sample of its values.
/// </summary>
/// <remarks>
/// The declared type alone is wrong both ways. Oracle's SDO_GEOMETRY and SQL Server's geography declare themselves spatial
/// and hand over text no reader can draw, so a type-only gate offers a map that draws nothing; MongoDB's GeoJSON arrives
/// in a document column, so a type-only gate never offers one. A spatial type is believed unless its values contradict
/// it, which keeps the toggle steady as an empty or all-null page loads; any other column has to earn it with values.
/// </remarks>
public static class MapSourceDetector
{
    /// <summary>Enough to pass a column whose first rows are NULL without reading the page twice.</summary>
    public const int SampleSize = 4;

    /// <summary>A column with no spatial type needs more evidence, so more of it is read.</summary>
    public const int UntypedSampleSize = 8;

    private const int CoordinateSampleSize = 16;

    private static readonly HashSet<string> SpatialTypes = new(StringComparer.OrdinalIgnoreCase)
    {
        "geometry", "geography", "point", "linestring", "polygon", "multipoint", "multilinestring", "multipolygon",
        "geometrycollection", "geomcollection", "ring", "st_geometry", "st_point", "sdo_geometry", "geo_point", "geo_shape",
    };

    private static readonly HashSet<string> DocumentTypes = new(StringComparer.OrdinalIgnoreCase)
    {
        "json", "jsonb", "object", "document", "variant", "super",
    };

    private static readonly HashSet<string> LatitudeWords = new(StringComparer.OrdinalIgnoreCase) { "lat", "latitude" };

    private static readonly HashSet<string> LongitudeWords = new(StringComparer.OrdinalIgnoreCase) { "lon", "lng", "long", "longitude" };

    private enum ColumnRole
    {
        None,
        Spatial,
        Document,
        Untyped,
    }

    public static IReadOnlyList<MapSource> Find(ResultSet result)
    {
        ArgumentNullException.ThrowIfNull(result);
        var sources = new List<MapSource>();
        var columns = result.Columns;
        Dictionary<string, int>? totals = null;
        Dictionary<string, int>? seen = null;
        for (var i = 0; i < columns.Count; i++)
        {
            var role = Classify(columns[i]);
            if (role == ColumnRole.None || !Drawable(result, i, role))
            {
                continue;
            }

            totals ??= CountNames(columns);
            seen ??= new Dictionary<string, int>(StringComparer.Ordinal);
            var name = columns[i].Name;
            var occurrence = seen[name] = seen.GetValueOrDefault(name) + 1;
            var display = totals[name] > 1 ? string.Create(CultureInfo.InvariantCulture, $"{name} ({occurrence})") : name;
            sources.Add(MapSource.ForGeometry(i, display, role == ColumnRole.Untyped));
        }

        AddCoordinatePairs(result, sources);
        return sources;
    }

    public static bool HasSource(ResultSet result) => Find(result).Count > 0;

    /// <summary>A type name with its schema, arguments and ClickHouse wrappers removed: <c>MDSYS.SDO_GEOMETRY</c>, <c>Nullable(Point)</c>.</summary>
    internal static string BaseTypeName(string dataType)
    {
        var span = dataType.AsSpan().Trim();
        foreach (var wrapper in (ReadOnlySpan<string>)["Nullable(", "LowCardinality("])
        {
            if (span.StartsWith(wrapper, StringComparison.OrdinalIgnoreCase) && span.EndsWith(")"))
            {
                span = span[wrapper.Length..^1];
            }
        }

        var paren = span.IndexOf('(');
        if (paren >= 0)
        {
            span = span[..paren];
        }

        var space = span.IndexOf(' ');
        if (space >= 0)
        {
            span = span[..space];
        }

        var dot = span.LastIndexOf('.');
        if (dot >= 0)
        {
            span = span[(dot + 1)..];
        }

        return span.Trim('"').ToString();
    }

    private static ColumnRole Classify(ResultColumn column)
    {
        var type = Nullable.GetUnderlyingType(column.ClrType) ?? column.ClrType;
        if (column.IsNumeric || type == typeof(bool) || type == typeof(DateTime) || type == typeof(DateTimeOffset) || type == typeof(Guid)
            || type == typeof(TimeSpan) || type == typeof(DateOnly) || type == typeof(TimeOnly))
        {
            return ColumnRole.None;
        }

        var name = BaseTypeName(column.DataType);
        if (SpatialTypes.Contains(name))
        {
            return ColumnRole.Spatial;
        }

        if (DocumentTypes.Contains(name))
        {
            return ColumnRole.Document;
        }

        return type == typeof(string) || type == typeof(byte[]) || type == typeof(object) ? ColumnRole.Untyped : ColumnRole.None;
    }

    private static bool Drawable(ResultSet result, int column, ColumnRole role)
    {
        int readable = 0, undrawable = 0, unreadable = 0, sampled = 0;
        var limit = role == ColumnRole.Untyped ? UntypedSampleSize : SampleSize;
        foreach (var row in result.Rows)
        {
            if (column >= row.Length || SpatialValueReader.ReadCell(row[column], role == ColumnRole.Untyped) is not { } reading)
            {
                continue;
            }

            sampled++;
            if (reading.Value is { } value)
            {
                // POINT EMPTY is a legitimate value that says nothing about whether the column can be drawn.
                if (!value.Geometry.IsEmpty)
                {
                    readable++;
                    if (role != ColumnRole.Untyped)
                    {
                        break;
                    }
                }
            }
            else if (reading.Failure.Kind == SpatialFailureKind.UnsupportedGeometryType)
            {
                undrawable++;
            }
            else
            {
                unreadable++;
            }

            if (sampled >= limit)
            {
                break;
            }
        }

        return role switch
        {
            // A type the map cannot draw is still the reader recognizing geometry, so the map gets to name it.
            ColumnRole.Spatial => readable > 0 || undrawable > 0 || unreadable == 0,
            ColumnRole.Document => readable > 0,
            _ => readable > 0 && unreadable == 0,
        };
    }

    private static Dictionary<string, int> CountNames(IReadOnlyList<ResultColumn> columns)
    {
        var totals = new Dictionary<string, int>(StringComparer.Ordinal);
        foreach (var column in columns)
        {
            totals[column.Name] = totals.GetValueOrDefault(column.Name) + 1;
        }

        return totals;
    }

    /// <summary>
    /// Pairs a latitude column with the longitude column sharing its stem, so <c>pickup_lat</c> meets <c>pickup_lng</c>
    /// and <c>latitude</c> meets <c>longitude</c>. Every sampled pair has to be in range, which rules out the many columns
    /// merely named <c>long</c> or <c>x</c>.
    /// </summary>
    private static void AddCoordinatePairs(ResultSet result, List<MapSource> sources)
    {
        var columns = result.Columns;
        List<(int Index, string Stem)>? latitudes = null;
        List<(int Index, string Stem)>? longitudes = null;
        for (var i = 0; i < columns.Count; i++)
        {
            if (!CanHoldCoordinate(columns[i]))
            {
                continue;
            }

            switch (CoordinateRole(columns[i].Name, out var stem))
            {
                case 1:
                    (latitudes ??= []).Add((i, stem));
                    break;
                case 2:
                    (longitudes ??= []).Add((i, stem));
                    break;
            }
        }

        if (latitudes is null || longitudes is null)
        {
            return;
        }

        foreach (var (latitude, stem) in latitudes)
        {
            var match = longitudes.FindIndex(l => string.Equals(l.Stem, stem, StringComparison.OrdinalIgnoreCase));
            if (match < 0)
            {
                continue;
            }

            var longitude = longitudes[match].Index;
            if (CoordinatesInRange(result, latitude, longitude))
            {
                longitudes.RemoveAt(match);
                sources.Add(MapSource.ForCoordinates(latitude, longitude, $"{columns[latitude].Name}, {columns[longitude].Name}"));
            }
        }
    }

    private static bool CanHoldCoordinate(ResultColumn column) => column.IsNumeric || column.ClrType == typeof(string);

    /// <summary>1 for latitude, 2 for longitude, 0 otherwise; <paramref name="stem"/> is the name without its role word.</summary>
    internal static int CoordinateRole(string name, out string stem)
    {
        stem = string.Empty;
        if (name.Equals("y", StringComparison.OrdinalIgnoreCase))
        {
            return 1;
        }

        if (name.Equals("x", StringComparison.OrdinalIgnoreCase))
        {
            return 2;
        }

        var words = SplitWords(name);
        for (var i = 0; i < words.Count; i++)
        {
            var role = LatitudeWords.Contains(words[i]) ? 1 : LongitudeWords.Contains(words[i]) ? 2 : 0;
            if (role != 0)
            {
                words.RemoveAt(i);
                stem = string.Join('_', words);
                return role;
            }
        }

        return 0;
    }

    /// <summary>Splits at separators and at a lower-to-upper case change, so <c>pickupLat</c> reads as pickup and lat.</summary>
    private static List<string> SplitWords(string name)
    {
        var words = new List<string>();
        var start = -1;
        for (var i = 0; i <= name.Length; i++)
        {
            var boundary = i == name.Length || !char.IsLetterOrDigit(name[i])
                || (i > 0 && char.IsUpper(name[i]) && char.IsLower(name[i - 1]));
            if (boundary && start >= 0)
            {
                words.Add(name[start..i].ToLowerInvariant());
                start = -1;
            }

            if (i < name.Length && char.IsLetterOrDigit(name[i]) && start < 0)
            {
                start = i;
            }
        }

        return words;
    }

    private static bool CoordinatesInRange(ResultSet result, int latitudeColumn, int longitudeColumn)
    {
        var sampled = 0;
        foreach (var row in result.Rows)
        {
            if (row[latitudeColumn] is null || row[longitudeColumn] is null)
            {
                continue;
            }

            if (ToCoordinate(row[latitudeColumn], row[longitudeColumn]) is not { IsValid: true })
            {
                return false;
            }

            if (++sampled >= CoordinateSampleSize)
            {
                break;
            }
        }

        // Typed numbers with nothing to contradict them keep the toggle steady while an empty page loads.
        return sampled > 0 || (result.Columns[latitudeColumn].IsNumeric && result.Columns[longitudeColumn].IsNumeric && result.RowCount == 0);
    }

    /// <summary>A coordinate from two cells holding numbers or numeric text, or null when either is something else.</summary>
    public static GeographicCoordinate? ToCoordinate(object? latitude, object? longitude) =>
        ToDouble(latitude) is { } lat && ToDouble(longitude) is { } lon ? new GeographicCoordinate(lon, lat) : null;

    internal static double? ToDouble(object? value) => value switch
    {
        double d => d,
        float f => f,
        decimal m => (double)m,
        int i => i,
        long l => l,
        short s => s,
        byte b => b,
        sbyte sb => sb,
        ushort us => us,
        uint ui => ui,
        ulong ul => ul,
        BigInteger big => (double)big,
        string text => double.TryParse(text, NumberStyles.Float, CultureInfo.InvariantCulture, out var parsed) ? parsed : null,
        _ => null,
    };
}
