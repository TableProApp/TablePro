using System.Collections.Immutable;
using System.Globalization;

namespace TablePro.Core.Geometry;

/// <summary>
/// Reads the WKT and EWKT spellings the engines actually emit, which is more tolerant than the OGC grammar.
/// </summary>
/// <remarks>
/// PostGIS writes <c>SRID=n;</c> only when the SRID is non-zero, writes XYZ as a bare <c>POINT(1 2 3)</c>, writes XYM as
/// <c>POINTM(1 2 3)</c> rather than <c>POINT M (...)</c>, and writes MULTIPOINT bare. MySQL writes the parenthesised
/// <c>MULTIPOINT((1 2),(3 4))</c>, spells the collection <c>GEOMCOLLECTION</c> and emits an invalid
/// <c>GEOMETRYCOLLECTION()</c> for an empty one. DuckDB puts a space before the paren. A curved or polyhedral type is
/// refused by name rather than dropped, so the map can say which keyword it cannot draw.
/// </remarks>
public static class WktGeometryReader
{
    private static readonly string[] UnsupportedKeywords =
    [
        "CIRCULARSTRING", "COMPOUNDCURVE", "CURVEPOLYGON", "MULTICURVE", "MULTISURFACE", "POLYHEDRALSURFACE", "TIN", "TRIANGLE",
    ];

    // Longest first: stripping M from MULTIPOINT before trying the whole word would leave MULTIPOIN.
    private static readonly string[] FusedDimensionTags = ["ZM", "Z", "M"];

    private enum Keyword
    {
        Point,
        LineString,
        Polygon,
        MultiPoint,
        MultiLineString,
        MultiPolygon,
        Collection,
    }

    public static SpatialReading Read(string text)
    {
        ArgumentNullException.ThrowIfNull(text);
        var scanner = new Scanner(text);
        var srid = scanner.ReadSridPrefix();
        var geometry = scanner.ReadGeometry();
        if (geometry is null)
        {
            return scanner.Failure ?? SpatialReadFailure.NotGeometry;
        }

        scanner.SkipWhitespace();
        return scanner.IsAtEnd ? new SpatialValue(srid, geometry) : SpatialReadFailure.Malformed;
    }

    /// <summary>Whether the text opens like a geometry, cheaply enough to ask of every cell in a column of strings.</summary>
    public static bool LooksLikeWkt(ReadOnlySpan<char> text)
    {
        var scanner = new Scanner(text);
        scanner.ReadSridPrefix();
        return Resolve(scanner.PeekKeyword()) is not null;
    }

    private static Keyword? Resolve(ReadOnlySpan<char> word)
    {
        if (word.IsEmpty)
        {
            return null;
        }

        if (Exact(word) is { } exact)
        {
            return exact;
        }

        foreach (var tag in FusedDimensionTags)
        {
            if (word.Length > tag.Length && word.EndsWith(tag, StringComparison.OrdinalIgnoreCase) && Exact(word[..^tag.Length]) is { } stripped)
            {
                return stripped;
            }
        }

        return null;
    }

    private static Keyword? Exact(ReadOnlySpan<char> word)
    {
        static bool Is(ReadOnlySpan<char> w, string k) => w.Equals(k, StringComparison.OrdinalIgnoreCase);
        if (Is(word, "POINT"))
        {
            return Keyword.Point;
        }

        if (Is(word, "LINESTRING"))
        {
            return Keyword.LineString;
        }

        if (Is(word, "POLYGON"))
        {
            return Keyword.Polygon;
        }

        if (Is(word, "MULTIPOINT"))
        {
            return Keyword.MultiPoint;
        }

        if (Is(word, "MULTILINESTRING"))
        {
            return Keyword.MultiLineString;
        }

        if (Is(word, "MULTIPOLYGON"))
        {
            return Keyword.MultiPolygon;
        }

        return Is(word, "GEOMETRYCOLLECTION") || Is(word, "GEOMCOLLECTION") ? Keyword.Collection : null;
    }

    /// <summary>PostGIS fuses the M tag onto a curved type's name as onto POINTM, so the base name is reported.</summary>
    private static string? UnsupportedKeyword(ReadOnlySpan<char> word)
    {
        foreach (var keyword in UnsupportedKeywords)
        {
            if (word.Equals(keyword, StringComparison.OrdinalIgnoreCase))
            {
                return keyword;
            }

            foreach (var tag in FusedDimensionTags)
            {
                if (word.Length == keyword.Length + tag.Length && word.StartsWith(keyword, StringComparison.OrdinalIgnoreCase)
                    && word.EndsWith(tag, StringComparison.OrdinalIgnoreCase))
                {
                    return keyword;
                }
            }
        }

        return null;
    }

    private ref struct Scanner(ReadOnlySpan<char> text)
    {
        private readonly ReadOnlySpan<char> _text = text;
        private int _index;
        private int _depth;

        public SpatialReadFailure? Failure { get; private set; }

        public readonly bool IsAtEnd => _index >= _text.Length;

        public void SkipWhitespace()
        {
            while (_index < _text.Length && _text[_index] is ' ' or '\t' or '\n' or '\r')
            {
                _index++;
            }
        }

        /// <summary>Consumes <c>SRID=n;</c> if present, leaving the cursor untouched if not.</summary>
        public int? ReadSridPrefix()
        {
            var start = _index;
            if (!MatchKeyword("SRID"))
            {
                return null;
            }

            SkipWhitespace();
            if (!Consume('='))
            {
                _index = start;
                return null;
            }

            SkipWhitespace();
            var negative = Consume('-');
            long value = 0;
            var digits = 0;
            while (_index < _text.Length && char.IsAsciiDigit(_text[_index]))
            {
                value = Math.Min((value * 10) + (_text[_index] - '0'), int.MaxValue);
                digits++;
                _index++;
            }

            SkipWhitespace();
            if (digits == 0 || !Consume(';'))
            {
                _index = start;
                return null;
            }

            // Zero means nobody named a system, as EWKB reads it; one value must not draw in one spelling only.
            var srid = (int)(negative ? -value : value);
            return srid == 0 ? null : srid;
        }

        public SpatialGeometry? ReadGeometry()
        {
            _depth++;
            try
            {
                if (_depth > SpatialLimits.MaximumNestingDepth)
                {
                    return Fail(SpatialReadFailure.Malformed);
                }

                var word = ReadKeyword();
                if (word.IsEmpty)
                {
                    return Fail(SpatialReadFailure.NotGeometry);
                }

                if (UnsupportedKeyword(word) is { } unsupported)
                {
                    return Fail(SpatialReadFailure.Unsupported(unsupported));
                }

                if (Resolve(word) is not { } keyword)
                {
                    return Fail(SpatialReadFailure.NotGeometry);
                }

                if (MatchKeyword("EMPTY"))
                {
                    return EmptyGeometry.Instance;
                }

                if ((MatchKeyword("ZM") || MatchKeyword("Z") || MatchKeyword("M")) && MatchKeyword("EMPTY"))
                {
                    return EmptyGeometry.Instance;
                }

                SkipWhitespace();
                if (!Consume('('))
                {
                    return Fail(SpatialReadFailure.Malformed);
                }

                SkipWhitespace();

                // MySQL emits GEOMETRYCOLLECTION() for an empty collection, which no grammar allows.
                if (Consume(')'))
                {
                    return EmptyGeometry.Instance;
                }

                var body = ReadBody(keyword);
                if (body is null)
                {
                    return null;
                }

                SkipWhitespace();
                return Consume(')') ? body : Fail(SpatialReadFailure.Malformed);
            }
            finally
            {
                _depth--;
            }
        }

        private SpatialGeometry? ReadBody(Keyword keyword) => keyword switch
        {
            Keyword.Point => ReadPoint() is { } point ? new PointGeometry(point) : null,
            Keyword.LineString => ReadPointList() is { } points ? new LineStringGeometry(points) : null,
            Keyword.Polygon => ReadRingList() is { } rings ? new PolygonGeometry(rings) : null,
            Keyword.MultiPoint => ReadMultiPointBody() is { } multi ? new MultiPointGeometry(multi) : null,
            Keyword.MultiLineString => ReadRingList() is { } lines ? new MultiLineStringGeometry(lines) : null,
            Keyword.MultiPolygon => ReadPolygonList() is { } polygons ? new MultiPolygonGeometry(polygons) : null,
            _ => ReadCollectionBody() is { } children ? new GeometryCollection(children) : null,
        };

        /// <summary>Both MULTIPOINT spellings ship, so the shape is decided per element rather than up front.</summary>
        private ImmutableArray<SpatialPoint>? ReadMultiPointBody()
        {
            var points = ImmutableArray.CreateBuilder<SpatialPoint>();
            do
            {
                SkipWhitespace();
                if (Consume('('))
                {
                    SkipWhitespace();
                    if (Consume(')'))
                    {
                        continue;
                    }

                    if (ReadPoint() is not { } point)
                    {
                        return null;
                    }

                    SkipWhitespace();
                    if (!Consume(')'))
                    {
                        Failure = SpatialReadFailure.Malformed;
                        return null;
                    }

                    points.Add(point);
                }
                else if (!MatchKeyword("EMPTY"))
                {
                    if (ReadPoint() is not { } point)
                    {
                        return null;
                    }

                    points.Add(point);
                }

                SkipWhitespace();
            }
            while (Consume(','));
            return points.DrainToImmutable();
        }

        private ImmutableArray<SpatialGeometry>? ReadCollectionBody()
        {
            var children = ImmutableArray.CreateBuilder<SpatialGeometry>();
            do
            {
                if (ReadGeometry() is not { } child)
                {
                    return null;
                }

                children.Add(child);
                SkipWhitespace();
            }
            while (Consume(','));
            return children.DrainToImmutable();
        }

        private ImmutableArray<ImmutableArray<ImmutableArray<SpatialPoint>>>? ReadPolygonList()
        {
            var polygons = ImmutableArray.CreateBuilder<ImmutableArray<ImmutableArray<SpatialPoint>>>();
            do
            {
                if (MatchKeyword("EMPTY"))
                {
                    polygons.Add([]);
                    SkipWhitespace();
                    continue;
                }

                SkipWhitespace();
                if (!Consume('('))
                {
                    Failure = SpatialReadFailure.Malformed;
                    return null;
                }

                if (ReadRingList() is not { } rings)
                {
                    return null;
                }

                SkipWhitespace();
                if (!Consume(')'))
                {
                    Failure = SpatialReadFailure.Malformed;
                    return null;
                }

                polygons.Add(rings);
                SkipWhitespace();
            }
            while (Consume(','));
            return polygons.DrainToImmutable();
        }

        private ImmutableArray<ImmutableArray<SpatialPoint>>? ReadRingList()
        {
            var rings = ImmutableArray.CreateBuilder<ImmutableArray<SpatialPoint>>();
            do
            {
                if (MatchKeyword("EMPTY"))
                {
                    rings.Add([]);
                    SkipWhitespace();
                    continue;
                }

                SkipWhitespace();
                if (!Consume('('))
                {
                    Failure = SpatialReadFailure.Malformed;
                    return null;
                }

                if (ReadPointList() is not { } points)
                {
                    return null;
                }

                SkipWhitespace();
                if (!Consume(')'))
                {
                    Failure = SpatialReadFailure.Malformed;
                    return null;
                }

                rings.Add(points);
                SkipWhitespace();
            }
            while (Consume(','));
            return rings.DrainToImmutable();
        }

        private ImmutableArray<SpatialPoint>? ReadPointList()
        {
            var points = ImmutableArray.CreateBuilder<SpatialPoint>();
            do
            {
                if (ReadPoint() is not { } point)
                {
                    return null;
                }

                points.Add(point);
                SkipWhitespace();
            }
            while (Consume(','));
            return points.DrainToImmutable();
        }

        /// <summary>
        /// Reads two to four ordinates and keeps the first two. The count is what tells XY from XYZ and XYZM in the bare
        /// PostGIS spelling, so extra ordinates are consumed rather than refused.
        /// </summary>
        private SpatialPoint? ReadPoint()
        {
            if (ReadDouble() is not { } x || ReadDouble() is not { } y)
            {
                Failure = SpatialReadFailure.Malformed;
                return null;
            }

            for (var extra = 0; extra < 2 && PeekStartsNumber(); extra++)
            {
                if (ReadDouble() is null)
                {
                    Failure = SpatialReadFailure.Malformed;
                    return null;
                }
            }

            return new SpatialPoint(x, y);
        }

        private bool PeekStartsNumber()
        {
            var saved = _index;
            SkipWhitespace();
            var starts = _index < _text.Length && (char.IsAsciiDigit(_text[_index]) || _text[_index] is '-' or '+' or '.');
            _index = saved;
            return starts;
        }

        private double? ReadDouble()
        {
            SkipWhitespace();
            var start = _index;
            if (_index < _text.Length && _text[_index] is '-' or '+')
            {
                _index++;
            }

            var sawDigit = SkipDigits();
            if (_index < _text.Length && _text[_index] == '.')
            {
                _index++;
                sawDigit |= SkipDigits();
            }

            if (!sawDigit)
            {
                _index = start;
                return null;
            }

            if (_index < _text.Length && _text[_index] is 'e' or 'E')
            {
                var exponentStart = _index++;
                if (_index < _text.Length && _text[_index] is '-' or '+')
                {
                    _index++;
                }

                if (!SkipDigits())
                {
                    _index = exponentStart;
                }
            }

            return double.TryParse(_text[start.._index], NumberStyles.Float, CultureInfo.InvariantCulture, out var value) ? value : null;
        }

        private bool SkipDigits()
        {
            var start = _index;
            while (_index < _text.Length && char.IsAsciiDigit(_text[_index]))
            {
                _index++;
            }

            return _index > start;
        }

        public ReadOnlySpan<char> PeekKeyword()
        {
            var saved = _index;
            var word = ReadKeyword();
            _index = saved;
            return word;
        }

        private ReadOnlySpan<char> ReadKeyword()
        {
            SkipWhitespace();
            var start = _index;
            while (_index < _text.Length && (char.IsAsciiLetter(_text[_index]) || _text[_index] == '_'))
            {
                _index++;
            }

            return _text[start.._index];
        }

        private bool MatchKeyword(string keyword)
        {
            var saved = _index;
            if (ReadKeyword().Equals(keyword, StringComparison.OrdinalIgnoreCase))
            {
                return true;
            }

            _index = saved;
            return false;
        }

        private bool Consume(char c)
        {
            if (_index < _text.Length && _text[_index] == c)
            {
                _index++;
                return true;
            }

            return false;
        }

        private SpatialGeometry? Fail(SpatialReadFailure failure)
        {
            Failure = failure;
            return null;
        }
    }
}
