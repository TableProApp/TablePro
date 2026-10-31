using System.Globalization;
using TablePro.Core.Connections;

namespace TablePro.Core.Copy;

/// <summary>What a declared column type holds, independent of how an engine spells it.</summary>
public enum SqlTypeCategory
{
    Integer,
    Decimal,
    Float,
    Text,
    Boolean,
    Date,
    Time,
    Timestamp,
    Uuid,
    Json,
    Binary,

    /// <summary>A MySQL ENUM or SET, whose labels are in <see cref="SqlTypeShape.Labels"/>.</summary>
    Enumeration,

    /// <summary>A value the server writes itself, such as SQL Server's <c>rowversion</c>: no INSERT may name it.</summary>
    ServerComputed,

    /// <summary>Arrays, intervals, geometry, XML, ranges and anything else no other category covers.</summary>
    Other,
}

/// <summary>
/// A declared column type read into its category and size, so the row generator knows what values fit and a copy to
/// another engine can say the same type in the target's words. Parsing is forgiving: an unknown name falls back to
/// SQLite's affinity rules on SQLite, and to <see cref="SqlTypeCategory.Other"/> elsewhere.
/// </summary>
public sealed record SqlTypeShape(SqlTypeCategory Category)
{
    /// <summary>Bytes of an integer: 1, 2, 3, 4 or 8.</summary>
    public int IntegerBytes { get; init; }

    public bool IsUnsigned { get; init; }

    /// <summary>The character or byte length of a text or binary type; null when unbounded.</summary>
    public int? Length { get; init; }

    public int? Precision { get; init; }

    public int? Scale { get; init; }

    public bool HasTimeZone { get; init; }

    /// <summary>A national character type (NVARCHAR, NCHAR), which SQL Server needs to keep Unicode.</summary>
    public bool IsNational { get; init; }

    public bool IsFixedLength { get; init; }

    public IReadOnlyList<string> Labels { get; init; } = [];

    public static SqlTypeShape Parse(string? dataType, DatabaseEngine engine)
    {
        var raw = (dataType ?? string.Empty).Trim();
        var lower = raw.ToLowerInvariant();
        if (lower.Length == 0)
        {
            // SQLite allows a column with no type at all; it takes any value, which reads best as text.
            return new SqlTypeShape(SqlTypeCategory.Text);
        }

        if (lower.EndsWith("[]", StringComparison.Ordinal) || (lower.StartsWith('_') && IsPostgres(engine)))
        {
            return new SqlTypeShape(SqlTypeCategory.Other);
        }

        var unsigned = lower.Contains(" unsigned", StringComparison.Ordinal);
        var (name, arguments) = Split(lower);
        if (name is "enum" or "set" && arguments is not null)
        {
            return new SqlTypeShape(SqlTypeCategory.Enumeration) { Labels = ParseLabels(raw) };
        }

        var first = Argument(arguments, 0);
        var second = Argument(arguments, 1);
        var unbounded = arguments?.Trim() == "max";
        var timeZone = lower.Contains("with time zone", StringComparison.Ordinal) || name is "timestamptz" or "timetz" or "datetimeoffset";

        var shape = name switch
        {
            "bool" or "boolean" => new SqlTypeShape(SqlTypeCategory.Boolean),
            "bit" when first is null or 1 => new SqlTypeShape(SqlTypeCategory.Boolean),
            "tinyint" when IsMySql(engine) && first == 1 => new SqlTypeShape(SqlTypeCategory.Boolean),

            // SQL Server's TINYINT has no sign.
            "tinyint" => Integer(1, unsigned || engine == DatabaseEngine.SqlServer),
            "int1" or "utinyint" => Integer(1, name == "utinyint"),
            "smallint" or "int2" or "smallserial" or "usmallint" => Integer(2, unsigned || name == "usmallint"),
            "mediumint" => Integer(3, unsigned),
            "int" or "integer" or "int4" or "serial" or "uinteger" or "serial4" =>
                Integer(IsSqlite(engine) ? 8 : 4, unsigned || name == "uinteger"),
            "bigint" or "int8" or "bigserial" or "ubigint" or "serial8" or "int64" => Integer(8, unsigned || name == "ubigint"),
            "hugeint" => new SqlTypeShape(SqlTypeCategory.Decimal) { Precision = 38, Scale = 0 },
            // Oracle has no integer type: NUMBER(p) with no fraction is one, sized by its digits.
            "number" when engine == DatabaseEngine.Oracle && second is null or 0 && first is > 0 and <= 18 => Integer(first <= 4 ? 2 : first <= 9 ? 4 : 8, false),
            "decimal" or "numeric" or "dec" or "number" or "fixed" => new SqlTypeShape(SqlTypeCategory.Decimal) { Precision = first, Scale = first is null ? null : second ?? 0 },
            "money" or "smallmoney" => new SqlTypeShape(SqlTypeCategory.Decimal) { Precision = 19, Scale = name == "money" && IsPostgres(engine) ? 2 : 4 },
            "real" or "float" or "float4" or "float8" or "double" or "double precision" or "binary_float" or "binary_double" or "float64" =>
                new SqlTypeShape(SqlTypeCategory.Float),
            "char" or "character" or "nchar" or "bpchar" or "national character" =>
                new SqlTypeShape(SqlTypeCategory.Text) { Length = first ?? 1, IsFixedLength = true, IsNational = name.StartsWith('n') },
            "varchar" or "character varying" or "nvarchar" or "varchar2" or "nvarchar2" or "national character varying" or "string" or "varying character" =>
                new SqlTypeShape(SqlTypeCategory.Text) { Length = unbounded ? null : first, IsNational = name.StartsWith('n') },
            "text" or "tinytext" or "mediumtext" or "longtext" or "clob" or "nclob" or "ntext" or "citext" or "name" or "long" =>
                new SqlTypeShape(SqlTypeCategory.Text) { Length = name == "tinytext" ? 255 : null, IsNational = name is "ntext" or "nclob" },
            "date" when engine == DatabaseEngine.Oracle => new SqlTypeShape(SqlTypeCategory.Timestamp),
            "date" => new SqlTypeShape(SqlTypeCategory.Date),
            "time" or "timetz" => new SqlTypeShape(SqlTypeCategory.Time) { HasTimeZone = timeZone },
            "timestamp" when engine == DatabaseEngine.SqlServer => new SqlTypeShape(SqlTypeCategory.ServerComputed),
            "rowversion" => new SqlTypeShape(SqlTypeCategory.ServerComputed),
            "timestamp" or "timestamptz" or "datetime" or "datetime2" or "smalldatetime" or "datetimeoffset" =>
                new SqlTypeShape(SqlTypeCategory.Timestamp) { HasTimeZone = timeZone },
            "year" => Integer(2, true),
            "uuid" or "uniqueidentifier" => new SqlTypeShape(SqlTypeCategory.Uuid),
            "json" or "jsonb" => new SqlTypeShape(SqlTypeCategory.Json),
            "bytea" or "blob" or "tinyblob" or "mediumblob" or "longblob" or "image" or "raw" or "long raw" or "bfile" =>
                new SqlTypeShape(SqlTypeCategory.Binary) { Length = name is "raw" ? first : name == "tinyblob" ? 255 : null },
            "binary" or "varbinary" =>
                new SqlTypeShape(SqlTypeCategory.Binary) { Length = unbounded ? null : first, IsFixedLength = name == "binary" },
            _ => null,
        };

        return shape ?? (IsSqlite(engine) ? Affinity(name) : new SqlTypeShape(SqlTypeCategory.Other));
    }

    private static SqlTypeShape Integer(int bytes, bool unsigned) => new(SqlTypeCategory.Integer) { IntegerBytes = bytes, IsUnsigned = unsigned };

    /// <summary>The smallest and largest value an integer of this shape holds.</summary>
    public (long Minimum, long Maximum) IntegerRange
    {
        get
        {
            var bits = Math.Clamp(IntegerBytes == 0 ? 8 : IntegerBytes, 1, 8) * 8;
            if (IsUnsigned)
            {
                return (0, bits >= 64 ? long.MaxValue : (1L << bits) - 1);
            }

            var maximum = bits >= 64 ? long.MaxValue : (1L << (bits - 1)) - 1;
            return (bits >= 64 ? long.MinValue : -maximum - 1, maximum);
        }
    }

    // SQLite's rules for a declared type it does not know, in its documented order.
    private static SqlTypeShape Affinity(string name)
    {
        if (name.Contains("int", StringComparison.Ordinal))
        {
            return Integer(8, false);
        }

        if (name.Contains("char", StringComparison.Ordinal) || name.Contains("clob", StringComparison.Ordinal) || name.Contains("text", StringComparison.Ordinal))
        {
            return new SqlTypeShape(SqlTypeCategory.Text);
        }

        if (name.Contains("blob", StringComparison.Ordinal))
        {
            return new SqlTypeShape(SqlTypeCategory.Binary);
        }

        return name.Contains("real", StringComparison.Ordinal) || name.Contains("floa", StringComparison.Ordinal) || name.Contains("doub", StringComparison.Ordinal)
            ? new SqlTypeShape(SqlTypeCategory.Float)
            : new SqlTypeShape(SqlTypeCategory.Decimal);
    }

    /// <summary>Splits <c>character varying(20)</c> into its name and argument text; trailing words such as UNSIGNED are dropped.</summary>
    private static (string Name, string? Arguments) Split(string lower)
    {
        var open = lower.IndexOf('(', StringComparison.Ordinal);
        string name;
        string? arguments = null;
        if (open >= 0)
        {
            var close = lower.LastIndexOf(')');
            arguments = close > open ? lower[(open + 1)..close] : lower[(open + 1)..];
            name = lower[..open].Trim();
        }
        else
        {
            name = lower;
        }

        foreach (var suffix in (ReadOnlySpan<string>)[" unsigned", " zerofill", " signed", " identity", " with time zone", " without time zone", " with local time zone"])
        {
            var at = name.IndexOf(suffix, StringComparison.Ordinal);
            if (at > 0)
            {
                name = name[..at];
            }
        }

        // `timestamp(3) with time zone` puts the precision inside the name.
        return (name.Trim(), arguments);
    }

    private static int? Argument(string? arguments, int index)
    {
        if (arguments is null)
        {
            return null;
        }

        var parts = arguments.Split(',', StringSplitOptions.TrimEntries);
        if (index >= parts.Length)
        {
            return null;
        }

        // Oracle writes VARCHAR2(20 CHAR) or (20 BYTE).
        var part = parts[index];
        var space = part.IndexOf(' ', StringComparison.Ordinal);
        if (space > 0)
        {
            part = part[..space];
        }

        return int.TryParse(part, NumberStyles.Integer, CultureInfo.InvariantCulture, out var value) ? value : null;
    }

    /// <summary>The quoted labels of <c>enum('a','b''c')</c>, unescaped.</summary>
    private static string[] ParseLabels(string raw)
    {
        var open = raw.IndexOf('(', StringComparison.Ordinal);
        var labels = new List<string>();
        var current = new System.Text.StringBuilder();
        var inQuote = false;
        for (var i = open + 1; i < raw.Length; i++)
        {
            var c = raw[i];
            if (inQuote)
            {
                if (c == '\'' && i + 1 < raw.Length && raw[i + 1] == '\'')
                {
                    current.Append('\'');
                    i++;
                }
                else if (c == '\'')
                {
                    labels.Add(current.ToString());
                    current.Clear();
                    inQuote = false;
                }
                else if (c == '\\' && i + 1 < raw.Length)
                {
                    current.Append(raw[++i]);
                }
                else
                {
                    current.Append(c);
                }
            }
            else if (c == '\'')
            {
                inQuote = true;
            }
            else if (c == ')')
            {
                break;
            }
        }

        return [.. labels];
    }

    internal static bool IsPostgres(DatabaseEngine engine) =>
        engine is DatabaseEngine.PostgreSql or DatabaseEngine.CockroachDb or DatabaseEngine.Redshift or DatabaseEngine.PGlite;

    internal static bool IsMySql(DatabaseEngine engine) =>
        engine is DatabaseEngine.MySql or DatabaseEngine.MariaDb or DatabaseEngine.TiDb or DatabaseEngine.OceanBase;

    internal static bool IsSqlite(DatabaseEngine engine) =>
        engine is DatabaseEngine.Sqlite or DatabaseEngine.LibSql or DatabaseEngine.Turso or DatabaseEngine.CloudflareD1;
}
