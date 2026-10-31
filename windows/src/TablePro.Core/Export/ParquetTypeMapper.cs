using System.Collections.Frozen;
using System.Globalization;
using System.Numerics;
using TablePro.Core.Results;
using TablePro.Core.Sql;

namespace TablePro.Core.Export;

/// <summary>The physical and logical shape a Parquet column is written in.</summary>
public enum ParquetColumnKind
{
    Text,
    Int64,
    Double,
    Boolean,
    Decimal,
    Date,
    Timestamp,

    /// <summary>A timestamp with an offset, written as UTC with the adjusted-to-UTC flag set.</summary>
    TimestampUtc,
    Time,
    Binary,
}

public readonly record struct ParquetColumnType(ParquetColumnKind Kind, int Precision = 0, int Scale = 0)
{
    public static readonly ParquetColumnType Text = new(ParquetColumnKind.Text);
}

/// <summary>
/// Chooses the Parquet type for a result column, as the macOS Parquet export plugin's type mapper does.
/// </summary>
/// <remarks>
/// Parquet is typed, so writing every column as text would read back with no numbers, dates or booleans. macOS can
/// only go by the engine's declared type because its streamed values arrive as text; here the provider's CLR type is
/// known and wins, and the declared type refines it (a decimal's precision, a date against a timestamp) or decides
/// alone when the driver hands over strings, as the REST engines do.
/// </remarks>
public static class ParquetTypeMapper
{
    /// <summary>The widest exact integer Parquet's INT64 holds without a decimal.</summary>
    private const int MaximumInt64Digits = 18;

    /// <summary>System.Decimal carries 28 significant digits, so a wider declared precision cannot be filled exactly.</summary>
    private const int MaximumDecimalDigits = 28;

    private static readonly FrozenSet<string> IntegerTypes = FrozenSet.Create(StringComparer.Ordinal,
        "int", "int2", "int4", "int8", "integer", "smallint", "bigint", "tinyint", "mediumint", "serial", "bigserial", "smallserial", "year",
        "int16", "int32", "int64", "uint8", "uint16", "uint32", "hugeint", "byteint");

    private static readonly FrozenSet<string> ExactNumericTypes = FrozenSet.Create(StringComparer.Ordinal, "decimal", "numeric", "number", "dec");

    private static readonly FrozenSet<string> ApproximateNumericTypes = FrozenSet.Create(StringComparer.Ordinal,
        "float", "float4", "float8", "float32", "float64", "double", "real", "binary_float", "binary_double");

    private static readonly FrozenSet<string> BooleanTypes = FrozenSet.Create(StringComparer.Ordinal, "bool", "boolean", "bit");

    private static readonly FrozenSet<string> TimestampTypes = FrozenSet.Create(StringComparer.Ordinal,
        "timestamp", "timestamptz", "datetime", "datetime2", "smalldatetime", "datetimeoffset", "datetime64");

    private static readonly FrozenSet<string> TimeTypes = FrozenSet.Create(StringComparer.Ordinal, "time", "timetz");

    private static readonly FrozenSet<string> BinaryTypes = FrozenSet.Create(StringComparer.Ordinal,
        "blob", "bytea", "binary", "varbinary", "longblob", "mediumblob", "tinyblob", "image", "raw", "bytes");

    public static ParquetColumnType Map(ResultColumn column, SqlDialect? dialect)
    {
        ArgumentNullException.ThrowIfNull(column);
        var declared = FromDeclaredType(column.DataType, dialect);
        var type = Nullable.GetUnderlyingType(column.ClrType) ?? column.ClrType;
        if (type == typeof(bool))
        {
            return new(ParquetColumnKind.Boolean);
        }

        if (type == typeof(long) || type == typeof(int) || type == typeof(short) || type == typeof(sbyte)
            || type == typeof(byte) || type == typeof(ushort) || type == typeof(uint))
        {
            return new(ParquetColumnKind.Int64);
        }

        if (type == typeof(ulong))
        {
            // Past long.MaxValue an unsigned 64-bit value needs 20 digits, which only a decimal holds exactly.
            return new(ParquetColumnKind.Decimal, 20, 0);
        }

        if (type == typeof(double) || type == typeof(float))
        {
            return new(ParquetColumnKind.Double);
        }

        if (type == typeof(decimal))
        {
            return declared.Kind is ParquetColumnKind.Decimal or ParquetColumnKind.Int64 ? declared : new(ParquetColumnKind.Double);
        }

        if (type == typeof(BigInteger))
        {
            // Arbitrary precision integers have no Parquet type that holds every value, so their digits stay exact as text.
            return ParquetColumnType.Text;
        }

        if (type == typeof(DateTime))
        {
            return declared.Kind == ParquetColumnKind.Date ? declared : new(ParquetColumnKind.Timestamp);
        }

        if (type == typeof(DateOnly))
        {
            return new(ParquetColumnKind.Date);
        }

        if (type == typeof(DateTimeOffset))
        {
            return new(ParquetColumnKind.TimestampUtc);
        }

        if (type == typeof(TimeOnly))
        {
            return new(ParquetColumnKind.Time);
        }

        if (type == typeof(TimeSpan))
        {
            // A time of day fits Parquet's TIME; an interval can exceed a day or be negative, so it stays text.
            return declared.Kind == ParquetColumnKind.Time ? declared : ParquetColumnType.Text;
        }

        if (type == typeof(byte[]))
        {
            return new(ParquetColumnKind.Binary);
        }

        if (type == typeof(string) || type == typeof(object))
        {
            return declared;
        }

        return ParquetColumnType.Text;
    }

    /// <summary>The type the declared type name alone suggests, or text when nothing better is known.</summary>
    public static ParquetColumnType FromDeclaredType(string? typeName, SqlDialect? dialect)
    {
        if (string.IsNullOrWhiteSpace(typeName))
        {
            return ParquetColumnType.Text;
        }

        var baseName = BaseName(typeName);
        if (dialect is SqlServerDialect)
        {
            if (baseName == "money")
            {
                return new(ParquetColumnKind.Decimal, 19, 4);
            }

            if (baseName == "smallmoney")
            {
                return new(ParquetColumnKind.Decimal, 10, 4);
            }
        }

        if (IntegerTypes.Contains(baseName))
        {
            return new(ParquetColumnKind.Int64);
        }

        if (ExactNumericTypes.Contains(baseName))
        {
            // SQLite stores NUMERIC(10,2) with numeric affinity and keeps no precision, so the declaration promises nothing.
            return dialect is SqliteDialect ? new(ParquetColumnKind.Double) : ExactNumeric(Unwrap(typeName));
        }

        if (ApproximateNumericTypes.Contains(baseName))
        {
            return new(ParquetColumnKind.Double);
        }

        if (BooleanTypes.Contains(baseName))
        {
            return new(ParquetColumnKind.Boolean);
        }

        if (baseName is "date" or "date32")
        {
            return new(ParquetColumnKind.Date);
        }

        if (TimestampTypes.Contains(baseName))
        {
            return new(ParquetColumnKind.Timestamp);
        }

        if (TimeTypes.Contains(baseName))
        {
            return new(ParquetColumnKind.Time);
        }

        return BinaryTypes.Contains(baseName) ? new(ParquetColumnKind.Binary) : ParquetColumnType.Text;
    }

    /// <summary>
    /// The first word of a type name, lowercased, without its arguments: <c>VARCHAR(64)</c> is <c>varchar</c> and
    /// <c>TIMESTAMP WITH TIME ZONE</c> is <c>timestamp</c>. ClickHouse wraps types in <c>Nullable(...)</c>, which is unwrapped.
    /// </summary>
    public static string BaseName(string typeName)
    {
        var span = Unwrap(typeName);
        var end = span.IndexOfAny('(', ' ');
        if (end >= 0)
        {
            span = span[..end];
        }

        return span.ToString().ToLowerInvariant();
    }

    private static ReadOnlySpan<char> Unwrap(string typeName)
    {
        var span = typeName.AsSpan().Trim();
        while ((span.StartsWith("Nullable(", StringComparison.OrdinalIgnoreCase) || span.StartsWith("LowCardinality(", StringComparison.OrdinalIgnoreCase))
            && span.EndsWith(')'))
        {
            span = span[(span.IndexOf('(') + 1)..^1].Trim();
        }

        return span;
    }

    private static ParquetColumnType ExactNumeric(ReadOnlySpan<char> typeName)
    {
        var open = typeName.IndexOf('(');
        var close = open < 0 ? -1 : typeName[open..].IndexOf(')') + open;
        if (open < 0 || close < open)
        {
            // A NUMERIC with no precision holds any value, so only a double is sure to take it.
            return new(ParquetColumnKind.Double);
        }

        var arguments = typeName[(open + 1)..close];
        var comma = arguments.IndexOf(',');
        var precisionText = (comma < 0 ? arguments : arguments[..comma]).Trim();
        var scaleText = comma < 0 ? "0".AsSpan() : arguments[(comma + 1)..].Trim();
        if (!int.TryParse(precisionText, NumberStyles.None, CultureInfo.InvariantCulture, out var precision)
            || !int.TryParse(scaleText, NumberStyles.None, CultureInfo.InvariantCulture, out var scale)
            || precision < 1 || scale > precision)
        {
            return new(ParquetColumnKind.Double);
        }

        if (scale == 0 && precision <= MaximumInt64Digits)
        {
            return new(ParquetColumnKind.Int64);
        }

        return precision <= MaximumDecimalDigits ? new(ParquetColumnKind.Decimal, precision, scale) : new(ParquetColumnKind.Double);
    }
}
