using System.Globalization;
using System.Numerics;
using System.Text;
using Parquet;
using Parquet.Schema;
using TablePro.Core.Results;

namespace TablePro.Core.Export;

/// <summary>The codecs the macOS Parquet export offers. Snappy is what every reader supports.</summary>
public enum ParquetCompression
{
    Snappy,
    Zstd,
    Gzip,
    None,
}

/// <summary>
/// Writes a result as Apache Parquet, one row group at a time, with typed, nullable columns.
/// </summary>
/// <remarks>
/// macOS stages rows in an in-memory DuckDB and lets its COPY encode the file. Core references no driver, so the
/// managed Parquet.Net encoder writes it instead; the column types and the defaults (Snappy, 122,880 rows a group,
/// every column optional) match what the macOS plugin produces. A value that cannot be read as its column's type is
/// written as null, as DuckDB's <c>TRY_CAST</c> does there, so one bad value does not cost the file.
/// </remarks>
internal static class ParquetExporter
{
    public static async Task WriteAsync(ResultSet result, IReadOnlyList<int>? rows, Stream stream, ExportOptions options, CancellationToken cancellationToken)
    {
        if (result.Columns.Count == 0)
        {
            throw new InvalidOperationException("A result with no columns cannot be written as Parquet.");
        }

        var types = new ParquetColumnType[result.Columns.Count];
        var fields = new DataField[types.Length];
        var names = UniqueNames(result.Columns);
        for (var i = 0; i < types.Length; i++)
        {
            types[i] = ParquetTypeMapper.Map(result.Columns[i], options.Dialect);
            fields[i] = CreateField(names[i], types[i]);
        }

        var parquetOptions = new ParquetOptions
        {
            CompressionMethod = options.ParquetCompression switch
            {
                ParquetCompression.Zstd => CompressionMethod.Zstd,
                ParquetCompression.Gzip => CompressionMethod.Gzip,
                ParquetCompression.None => CompressionMethod.None,
                _ => CompressionMethod.Snappy,
            },

            // The library defaults to SmallestSize, which makes Gzip and Zstd several times slower for a few percent.
            CompressionLevel = System.IO.Compression.CompressionLevel.Optimal,
        };

        var total = rows?.Count ?? result.RowCount;
        var groupSize = Math.Clamp(options.ParquetRowGroupSize, 1, Math.Max(1, total));
        var buffers = new ColumnBuffers(groupSize);
        await using var writer = await ParquetWriter.CreateAsync(new ParquetSchema(fields), stream, parquetOptions, append: false, cancellationToken);
        for (var start = 0; start < total; start += groupSize)
        {
            var count = Math.Min(groupSize, total - start);
            using var group = writer.CreateRowGroup();
            for (var column = 0; column < fields.Length; column++)
            {
                cancellationToken.ThrowIfCancellationRequested();
                await WriteColumnAsync(group, fields[column], types[column], result, rows, start, count, column, buffers, cancellationToken);
            }
        }
    }

    /// <summary>
    /// Parquet readers address columns by name, so a join's two <c>id</c> columns would collide; later ones get a suffix,
    /// and an unnamed expression gets its position.
    /// </summary>
    internal static string[] UniqueNames(IReadOnlyList<ResultColumn> columns)
    {
        var names = new string[columns.Count];
        var used = new HashSet<string>(StringComparer.Ordinal);
        for (var i = 0; i < names.Length; i++)
        {
            var name = string.IsNullOrWhiteSpace(columns[i].Name) ? string.Create(CultureInfo.InvariantCulture, $"column_{i + 1}") : columns[i].Name;
            var unique = name;
            for (var suffix = 2; !used.Add(unique); suffix++)
            {
                unique = string.Create(CultureInfo.InvariantCulture, $"{name}_{suffix}");
            }

            names[i] = unique;
        }

        return names;
    }

    private static DataField CreateField(string name, ParquetColumnType type) => type.Kind switch
    {
        ParquetColumnKind.Int64 => new DataField(name, typeof(long), isNullable: true),
        ParquetColumnKind.Double => new DataField(name, typeof(double), isNullable: true),
        ParquetColumnKind.Boolean => new DataField(name, typeof(bool), isNullable: true),
        ParquetColumnKind.Decimal => new DecimalDataField(name, type.Precision, type.Scale, forceByteArrayEncoding: false, isNullable: true),
        ParquetColumnKind.Date => new DataField(name, typeof(DateOnly), isNullable: true),
        ParquetColumnKind.Timestamp => new DateTimeDataField(name, DateTimeFormat.Timestamp, isAdjustedToUTC: false, unit: DateTimeTimeUnit.Micros, isNullable: true),
        ParquetColumnKind.TimestampUtc => new DateTimeDataField(name, DateTimeFormat.Timestamp, isAdjustedToUTC: true, unit: DateTimeTimeUnit.Micros, isNullable: true),
        ParquetColumnKind.Time => new TimeDataField(name, TimeUnitPrecision.Micros, isNullable: true),
        ParquetColumnKind.Binary => new DataField(name, typeof(byte[]), isNullable: true),
        _ => new DataField(name, typeof(string), isNullable: true),
    };

    private static Task WriteColumnAsync(
        ParquetRowGroupWriter group, DataField field, ParquetColumnType type, ResultSet result, IReadOnlyList<int>? rows,
        int start, int count, int column, ColumnBuffers buffers, CancellationToken ct)
    {
        switch (type.Kind)
        {
            case ParquetColumnKind.Int64:
                return Fill(buffers.Int64s, ParquetValues.ToInt64);
            case ParquetColumnKind.Double:
                return Fill(buffers.Doubles, ParquetValues.ToDouble);
            case ParquetColumnKind.Boolean:
                return Fill(buffers.Booleans, ParquetValues.ToBoolean);
            case ParquetColumnKind.Decimal:
                return Fill(buffers.Decimals, v => ParquetValues.ToDecimal(v, type.Precision, type.Scale));
            case ParquetColumnKind.Date:
                return Fill(buffers.Dates, ParquetValues.ToDate);
            case ParquetColumnKind.Timestamp:
                return Fill(buffers.Timestamps, v => ParquetValues.ToTimestamp(v, utc: false));
            case ParquetColumnKind.TimestampUtc:
                return Fill(buffers.Timestamps, v => ParquetValues.ToTimestamp(v, utc: true));
            case ParquetColumnKind.Time:
                // The encoder takes a microsecond TIME as its physical INT64, microseconds since midnight.
                return Fill(buffers.Int64s, v => ParquetValues.ToTime(v) is { } time ? time.Ticks / TimeSpan.TicksPerMicrosecond : null);
            case ParquetColumnKind.Binary:
            {
                var values = buffers.Binaries;
                for (var i = 0; i < count; i++)
                {
                    values[i] = ParquetValues.ToBinary(Value(i));
                }

                return group.WriteAsync(field, new ArraySegment<byte[]>(values!, 0, count));
            }

            default:
            {
                var values = buffers.Strings;
                for (var i = 0; i < count; i++)
                {
                    values[i] = Value(i) is { } value ? CellFormatter.Format(value) : null;
                }

                return group.WriteAsync(field, new ArraySegment<string>(values!, 0, count));
            }
        }

        object? Value(int offset)
        {
            var index = start + offset;
            var row = result.Rows[rows is null ? index : rows[index]];
            return row[column] is DBNull ? null : row[column];
        }

        Task Fill<T>(T?[] values, Func<object, T?> convert)
            where T : struct
        {
            for (var i = 0; i < count; i++)
            {
                values[i] = Value(i) is { } value ? convert(value) : null;
            }

            return group.WriteAsync<T>(field, new ReadOnlyMemory<T?>(values, 0, count), cancellationToken: ct);
        }
    }

    /// <summary>One reusable array per value type, sized to a row group, so columns after the first allocate nothing.</summary>
    private sealed class ColumnBuffers(int size)
    {
        private long?[]? _int64s;
        private double?[]? _doubles;
        private bool?[]? _booleans;
        private decimal?[]? _decimals;
        private DateOnly?[]? _dates;
        private DateTime?[]? _timestamps;
        private byte[]?[]? _binaries;
        private string?[]? _strings;

        public long?[] Int64s => _int64s ??= new long?[size];

        public double?[] Doubles => _doubles ??= new double?[size];

        public bool?[] Booleans => _booleans ??= new bool?[size];

        public decimal?[] Decimals => _decimals ??= new decimal?[size];

        public DateOnly?[] Dates => _dates ??= new DateOnly?[size];

        public DateTime?[] Timestamps => _timestamps ??= new DateTime?[size];

        public byte[]?[] Binaries => _binaries ??= new byte[]?[size];

        public string?[] Strings => _strings ??= new string?[size];
    }
}

/// <summary>Reads a provider value as a Parquet column's type, or null when it cannot be read as one.</summary>
internal static class ParquetValues
{
    private static readonly CultureInfo Invariant = CultureInfo.InvariantCulture;

    public static long? ToInt64(object value) => value switch
    {
        long l => l,
        int i => i,
        short s => s,
        sbyte sb => sb,
        byte b => b,
        ushort us => us,
        uint ui => ui,
        ulong ul when ul <= long.MaxValue => (long)ul,
        bool flag => flag ? 1 : 0,
        decimal m when decimal.Truncate(m) == m && m is >= long.MinValue and <= long.MaxValue => (long)m,
        double d when double.IsInteger(d) && d is >= long.MinValue and < 9.2233720368547758E18 => (long)d,
        float f when float.IsInteger(f) && f is >= long.MinValue and < 9.2233720368547758E18f => (long)f,
        BigInteger big when big >= long.MinValue && big <= long.MaxValue => (long)big,
        string text when long.TryParse(text.AsSpan().Trim(), NumberStyles.Integer, Invariant, out var parsed) => parsed,
        _ => null,
    };

    public static double? ToDouble(object value) => value switch
    {
        double d => d,
        float f => f,
        decimal m => (double)m,
        long l => l,
        int i => i,
        short s => s,
        sbyte sb => sb,
        byte b => b,
        ushort us => us,
        uint ui => ui,
        ulong ul => ul,
        BigInteger big => (double)big,
        bool flag => flag ? 1 : 0,
        string text when double.TryParse(text.AsSpan().Trim(), NumberStyles.Float, Invariant, out var parsed) => parsed,
        _ => null,
    };

    public static bool? ToBoolean(object value) => value switch
    {
        bool flag => flag,
        long l => l != 0,
        int i => i != 0,
        short s => s != 0,
        sbyte sb => sb != 0,
        byte b => b != 0,
        ushort us => us != 0,
        uint ui => ui != 0,
        ulong ul => ul != 0,
        decimal m => m != 0,
        string text => ParseBoolean(text.AsSpan().Trim()),
        _ => null,
    };

    /// <summary>Rounds to the column's scale, and refuses a value with more integer digits than its precision allows.</summary>
    public static decimal? ToDecimal(object value, int precision, int scale)
    {
        decimal number;
        try
        {
            switch (value)
            {
                case decimal m:
                    number = m;
                    break;
                case string text when decimal.TryParse(text.AsSpan().Trim(), NumberStyles.Float, Invariant, out var parsed):
                    number = parsed;
                    break;
                case string:
                case bool:
                case byte[]:
                    return null;
                case IConvertible convertible:
                    number = convertible.ToDecimal(Invariant);
                    break;
                case BigInteger big:
                    number = (decimal)big;
                    break;
                default:
                    return null;
            }
        }
        catch (OverflowException)
        {
            return null;
        }

        number = Math.Round(number, Math.Min(scale, 28), MidpointRounding.AwayFromZero);
        var integerDigits = precision - scale;
        var limit = integerDigits >= 28 ? decimal.MaxValue : Pow10(integerDigits);
        return Math.Abs(number) < limit ? number : null;
    }

    public static DateOnly? ToDate(object value) => value switch
    {
        DateOnly date => date,
        DateTime dt => DateOnly.FromDateTime(dt),
        DateTimeOffset dto => DateOnly.FromDateTime(dto.DateTime),
        string text when DateOnly.TryParse(text.AsSpan().Trim(), Invariant, DateTimeStyles.None, out var parsed) => parsed,
        string text when DateTime.TryParse(text.AsSpan().Trim(), Invariant, DateTimeStyles.None, out var parsed) => DateOnly.FromDateTime(parsed),
        _ => null,
    };

    /// <summary>
    /// An offset timestamp is stored as its UTC instant; a plain one keeps its wall-clock reading, since nothing says
    /// which zone it was in.
    /// </summary>
    public static DateTime? ToTimestamp(object value, bool utc) => value switch
    {
        DateTime dt => utc ? (dt.Kind == DateTimeKind.Local ? dt.ToUniversalTime() : DateTime.SpecifyKind(dt, DateTimeKind.Utc)) : DateTime.SpecifyKind(dt, DateTimeKind.Unspecified),
        DateTimeOffset dto => utc ? dto.UtcDateTime : dto.DateTime,
        DateOnly date => date.ToDateTime(TimeOnly.MinValue, utc ? DateTimeKind.Utc : DateTimeKind.Unspecified),
        string text when utc && DateTimeOffset.TryParse(text.AsSpan().Trim(), Invariant, DateTimeStyles.AssumeUniversal, out var parsed) => parsed.UtcDateTime,
        string text when !utc && DateTime.TryParse(text.AsSpan().Trim(), Invariant, DateTimeStyles.None, out var parsed) => parsed,
        _ => null,
    };

    public static TimeSpan? ToTime(object value) => value switch
    {
        TimeOnly time => time.ToTimeSpan(),
        TimeSpan span when span >= TimeSpan.Zero && span < TimeSpan.FromDays(1) => span,
        DateTime dt => dt.TimeOfDay,
        string text when TimeOnly.TryParse(text.AsSpan().Trim(), Invariant, DateTimeStyles.None, out var parsed) => parsed.ToTimeSpan(),
        _ => null,
    };

    public static byte[]? ToBinary(object? value) => value switch
    {
        null => null,
        byte[] bytes => bytes,
        string text => Encoding.UTF8.GetBytes(text),
        _ => Encoding.UTF8.GetBytes(CellFormatter.Format(value)),
    };

    private static bool? ParseBoolean(ReadOnlySpan<char> text)
    {
        if (text.Equals("true", StringComparison.OrdinalIgnoreCase) || text.Equals("t", StringComparison.OrdinalIgnoreCase)
            || text.Equals("yes", StringComparison.OrdinalIgnoreCase) || text.Equals("y", StringComparison.OrdinalIgnoreCase) || text is "1")
        {
            return true;
        }

        if (text.Equals("false", StringComparison.OrdinalIgnoreCase) || text.Equals("f", StringComparison.OrdinalIgnoreCase)
            || text.Equals("no", StringComparison.OrdinalIgnoreCase) || text.Equals("n", StringComparison.OrdinalIgnoreCase) || text is "0")
        {
            return false;
        }

        return null;
    }

    private static decimal Pow10(int exponent)
    {
        var result = 1m;
        for (var i = 0; i < exponent; i++)
        {
            result *= 10;
        }

        return result;
    }
}
