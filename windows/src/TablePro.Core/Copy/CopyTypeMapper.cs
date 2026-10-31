using System.Globalization;
using TablePro.Core.Connections;
using TablePro.Core.Import;
using TablePro.Core.Localization;
using TablePro.Core.Schema;
using TablePro.Core.Sql;

namespace TablePro.Core.Copy;

/// <summary>Engines that share one type system, so a declared type means the same on both and is copied as written.</summary>
public enum TypeFamily
{
    PostgreSql,
    MySql,
    Sqlite,
    SqlServer,
    Oracle,
    DuckDb,
    Other,
}

/// <summary>
/// Why a target type only approximates the source's. It is a kind rather than text so the review note can be one whole
/// sentence in the user's language.
/// </summary>
public enum CopyTypeApproximation
{
    /// <summary>The Oracle release has no BOOLEAN.</summary>
    NoBoolean,

    /// <summary>JSON is kept as text.</summary>
    JsonAsText,

    /// <summary>An enumeration becomes text without its allowed values.</summary>
    EnumerationAsText,

    /// <summary>Oracle has no TIME.</summary>
    NoTime,

    /// <summary>A time loses its time zone.</summary>
    TimeZoneDropped,

    /// <summary>A timestamp is kept in UTC since DATETIME holds no time zone.</summary>
    UtcNoTimeZone,

    /// <summary>A timestamp is kept in UTC.</summary>
    Utc,

    /// <summary>The value is written as text.</summary>
    AsText,

    /// <summary>The server's row versions are copied as bytes.</summary>
    RowVersionAsBytes,

    /// <summary>The type has no equivalent and becomes text.</summary>
    NoEquivalent,

    /// <summary>Cut to 255 characters to fit in a key.</summary>
    CutTo255,

    /// <summary>Cut to 450 characters to fit in a key.</summary>
    CutTo450,

    /// <summary>Cut to 4,000 characters to fit in a key.</summary>
    CutTo4000,
}

/// <summary>
/// Says a column's type, default and identity in the target engine's words. Within one family nothing is translated;
/// across families the type is read into a <see cref="SqlTypeShape"/> and written again, through
/// <see cref="ImportTypeMapper"/> for the plain integer, real, boolean, JSON and text types it already maps, and here for
/// the sized and temporal types it has no notion of. Every approximation comes back as a note for the review.
/// </summary>
public static class CopyTypeMapper
{
    public static TypeFamily FamilyOf(DatabaseEngine engine) => engine switch
    {
        _ when SqlTypeShape.IsPostgres(engine) => TypeFamily.PostgreSql,
        _ when SqlTypeShape.IsMySql(engine) => TypeFamily.MySql,
        _ when SqlTypeShape.IsSqlite(engine) => TypeFamily.Sqlite,
        DatabaseEngine.SqlServer => TypeFamily.SqlServer,
        DatabaseEngine.Oracle => TypeFamily.Oracle,
        DatabaseEngine.DuckDb => TypeFamily.DuckDb,
        _ => TypeFamily.Other,
    };

    /// <summary>Whether a type written for <paramref name="source"/> means the same on <paramref name="target"/>.</summary>
    public static bool SharesTypes(DatabaseEngine source, DatabaseEngine target) =>
        source == target || (FamilyOf(source) == FamilyOf(target) && FamilyOf(source) != TypeFamily.Other);

    /// <summary>A copy can cross engines only between families it knows how to translate.</summary>
    public static string? Refusal(DatabaseEngine source, DatabaseEngine target)
    {
        if (SharesTypes(source, target))
        {
            return null;
        }

        var unknown = FamilyOf(source) == TypeFamily.Other ? source : FamilyOf(target) == TypeFamily.Other ? target : (DatabaseEngine?)null;
        return unknown is { } engine
            ? CoreStrings.Format("Copy/UnknownTypeSystem", EngineDescriptor.For(engine).DisplayName)
            : null;
    }

    /// <summary>
    /// The target's definition of a source column. <paramref name="keyed"/> marks a column in a key or an index, which
    /// MySQL cannot build on an unbounded TEXT; <paramref name="writesRows"/> drops SQL Server's IDENTITY, which refuses
    /// the copied values through a parameterized insert.
    /// </summary>
    public static (ColumnDefinition Column, IReadOnlyList<string> Notes) Translate(
        ColumnInfo column, DatabaseEngine source, DatabaseEngine target, string? targetVersion, bool keyed, bool writesRows)
    {
        ArgumentNullException.ThrowIfNull(column);
        var notes = new List<string>();
        var shape = SqlTypeShape.Parse(column.DataType, source);
        var sequenceDefault = column.DefaultValue?.Contains("nextval(", StringComparison.OrdinalIgnoreCase) == true;
        var identity = column.IsIdentity || sequenceDefault;
        string type;
        string? defaultExpression;
        if (SharesTypes(source, target))
        {
            type = column.DataType;
            defaultExpression = sequenceDefault ? null : column.DefaultValue;
            if (sequenceDefault)
            {
                notes.Add(CoreStrings.Format("Copy/SequenceBecomesIdentity", column.Name));
            }
        }
        else
        {
            (type, var approximation) = TypeFor(shape, target, targetVersion, keyed);
            if (approximation is { } kind)
            {
                notes.Add(Describe(kind, column.Name, column.DataType, type));
            }

            defaultExpression = sequenceDefault ? null : PortableDefault(column.DefaultValue, shape, target);
            if (!string.IsNullOrWhiteSpace(column.DefaultValue) && !sequenceDefault && defaultExpression is null)
            {
                notes.Add(CoreStrings.Format("Copy/DefaultLeftOut", column.Name, column.DefaultValue.Trim()));
            }
        }

        if (identity && writesRows && target == DatabaseEngine.SqlServer)
        {
            identity = false;
            notes.Add(CoreStrings.Format("Copy/SqlServerIdentityDropped", column.Name));
        }

        if (shape.Category == SqlTypeCategory.ServerComputed && SharesTypes(source, target))
        {
            notes.Add(CoreStrings.Format("Copy/ServerWritten", column.Name));
        }

        return (new ColumnDefinition(column.Name, type, column.IsNullable && !column.IsPrimaryKey, defaultExpression, column.IsPrimaryKey, identity, column.Comment), notes);
    }

    /// <summary>The note for a column whose type is approximated, as one sentence per kind so every language can word it whole.</summary>
    private static string Describe(CopyTypeApproximation kind, string column, string from, string to) => kind switch
    {
        CopyTypeApproximation.NoBoolean => CoreStrings.Format("Copy/TypeNoBoolean", column, from, to),
        CopyTypeApproximation.JsonAsText => CoreStrings.Format("Copy/TypeJsonAsText", column, from, to),
        CopyTypeApproximation.EnumerationAsText => CoreStrings.Format("Copy/TypeEnumerationAsText", column, from, to),
        CopyTypeApproximation.NoTime => CoreStrings.Format("Copy/TypeNoTime", column, from, to),
        CopyTypeApproximation.TimeZoneDropped => CoreStrings.Format("Copy/TypeTimeZoneDropped", column, from, to),
        CopyTypeApproximation.UtcNoTimeZone => CoreStrings.Format("Copy/TypeUtcNoTimeZone", column, from, to),
        CopyTypeApproximation.Utc => CoreStrings.Format("Copy/TypeUtc", column, from, to),
        CopyTypeApproximation.AsText => CoreStrings.Format("Copy/TypeAsText", column, from, to),
        CopyTypeApproximation.RowVersionAsBytes => CoreStrings.Format("Copy/TypeRowVersionAsBytes", column, from, to),
        CopyTypeApproximation.NoEquivalent => CoreStrings.Format("Copy/TypeNoEquivalent", column, from, to),
        CopyTypeApproximation.CutTo255 => CoreStrings.Format("Copy/TypeCutTo255", column, from, to),
        CopyTypeApproximation.CutTo450 => CoreStrings.Format("Copy/TypeCutTo450", column, from, to),
        CopyTypeApproximation.CutTo4000 => CoreStrings.Format("Copy/TypeCutTo4000", column, from, to),
        _ => throw new ArgumentOutOfRangeException(nameof(kind)),
    };

    /// <summary>The target type for a shape, and why it is an approximation when it is one.</summary>
    public static (string Type, CopyTypeApproximation? Approximation) TypeFor(SqlTypeShape shape, DatabaseEngine target, string? targetVersion = null, bool keyed = false)
    {
        ArgumentNullException.ThrowIfNull(shape);
        var family = FamilyOf(target);
        string Mapped(ImportFieldType type) => ImportTypeMapper.SqlType(type, target, targetVersion);
        switch (shape.Category)
        {
            case SqlTypeCategory.Integer:
                return (IntegerType(shape, family) ?? Mapped(ImportFieldType.Integer), null);
            case SqlTypeCategory.Decimal:
                return (DecimalType(shape, family), null);
            case SqlTypeCategory.Float:
                return (Mapped(ImportFieldType.Real), null);
            case SqlTypeCategory.Boolean:
            {
                var type = Mapped(ImportFieldType.Boolean);
                return (type, family == TypeFamily.Oracle && !type.Equals("BOOLEAN", StringComparison.OrdinalIgnoreCase) ? CopyTypeApproximation.NoBoolean : null);
            }

            case SqlTypeCategory.Json:
                return (Mapped(ImportFieldType.Json), family is TypeFamily.Sqlite or TypeFamily.SqlServer or TypeFamily.Oracle ? CopyTypeApproximation.JsonAsText : null);
            case SqlTypeCategory.Text:
                return TextType(shape, family, keyed, Mapped(ImportFieldType.Text));
            case SqlTypeCategory.Enumeration:
            {
                var length = Math.Max(1, shape.Labels.Count == 0 ? 255 : shape.Labels.Max(l => l.Length));
                var (type, _) = TextType(new SqlTypeShape(SqlTypeCategory.Text) { Length = length }, family, keyed, Mapped(ImportFieldType.Text));
                return (type, CopyTypeApproximation.EnumerationAsText);
            }

            case SqlTypeCategory.Date:
                return ("DATE", null);
            case SqlTypeCategory.Time:
                return family switch
                {
                    TypeFamily.Oracle => ("INTERVAL DAY(0) TO SECOND", CopyTypeApproximation.NoTime),
                    TypeFamily.PostgreSql when shape.HasTimeZone => ("TIME WITH TIME ZONE", (CopyTypeApproximation?)null),
                    _ => ("TIME", shape.HasTimeZone ? CopyTypeApproximation.TimeZoneDropped : null),
                };
            case SqlTypeCategory.Timestamp:
                return family switch
                {
                    TypeFamily.PostgreSql => (shape.HasTimeZone ? "TIMESTAMP WITH TIME ZONE" : "TIMESTAMP", (CopyTypeApproximation?)null),
                    TypeFamily.MySql => ("DATETIME(6)", shape.HasTimeZone ? CopyTypeApproximation.UtcNoTimeZone : null),
                    TypeFamily.SqlServer => (shape.HasTimeZone ? "DATETIMEOFFSET" : "DATETIME2", null),
                    TypeFamily.Oracle => (shape.HasTimeZone ? "TIMESTAMP WITH TIME ZONE" : "TIMESTAMP", null),
                    TypeFamily.DuckDb => (shape.HasTimeZone ? "TIMESTAMPTZ" : "TIMESTAMP", null),
                    _ => ("DATETIME", shape.HasTimeZone ? CopyTypeApproximation.Utc : null),
                };
            case SqlTypeCategory.Uuid:
                return family switch
                {
                    TypeFamily.PostgreSql or TypeFamily.DuckDb => ("UUID", (CopyTypeApproximation?)null),
                    TypeFamily.SqlServer => ("UNIQUEIDENTIFIER", null),
                    TypeFamily.MySql => ("CHAR(36)", CopyTypeApproximation.AsText),
                    TypeFamily.Oracle => ("VARCHAR2(36 CHAR)", CopyTypeApproximation.AsText),
                    _ => ("TEXT", CopyTypeApproximation.AsText),
                };
            case SqlTypeCategory.Binary:
                return (BinaryType(shape, family), null);
            case SqlTypeCategory.ServerComputed:
                return (BinaryType(new SqlTypeShape(SqlTypeCategory.Binary) { Length = 8 }, family), CopyTypeApproximation.RowVersionAsBytes);
            default:
            {
                var (type, _) = TextType(new SqlTypeShape(SqlTypeCategory.Text), family, keyed, Mapped(ImportFieldType.Text));
                return (type, CopyTypeApproximation.NoEquivalent);
            }
        }
    }

    private static string? IntegerType(SqlTypeShape shape, TypeFamily family)
    {
        var bytes = shape.IntegerBytes;
        var unsigned = shape.IsUnsigned;

        // An unsigned value needs the next size up where the target has no unsigned types.
        var widened = unsigned && bytes < 8 ? bytes switch { 1 => 2, 2 => 4, 3 => 4, _ => 8 } : bytes;
        return family switch
        {
            TypeFamily.PostgreSql => widened <= 2 ? "SMALLINT" : widened <= 4 ? "INTEGER" : unsigned && bytes == 8 ? "NUMERIC(20)" : "BIGINT",
            TypeFamily.MySql => (bytes switch { 1 => "TINYINT", 2 => "SMALLINT", 3 => "MEDIUMINT", 4 => "INT", _ => "BIGINT" }) + (unsigned ? " UNSIGNED" : string.Empty),
            TypeFamily.SqlServer => bytes == 1 && unsigned ? "TINYINT" : widened <= 2 ? "SMALLINT" : widened <= 4 ? "INT" : unsigned && bytes == 8 ? "DECIMAL(20,0)" : "BIGINT",
            TypeFamily.Oracle => string.Create(CultureInfo.InvariantCulture, $"NUMBER({(widened <= 1 ? 3 : widened <= 2 ? 5 : widened <= 4 ? 10 : unsigned ? 20 : 19)})"),
            TypeFamily.DuckDb => (unsigned ? "U" : string.Empty) + (bytes switch { 1 => "TINYINT", 2 => "SMALLINT", 3 or 4 => "INTEGER", _ => "BIGINT" }),
            TypeFamily.Sqlite => "INTEGER",
            _ => null,
        };
    }

    private static string DecimalType(SqlTypeShape shape, TypeFamily family)
    {
        var (maxPrecision, fallback) = family switch
        {
            TypeFamily.MySql => (65, "DECIMAL(65,30)"),
            TypeFamily.SqlServer or TypeFamily.DuckDb => (38, "DECIMAL(38,10)"),
            TypeFamily.Oracle => (38, "NUMBER"),
            TypeFamily.Sqlite => (int.MaxValue, "NUMERIC"),
            _ => (1000, "NUMERIC"),
        };
        if (family == TypeFamily.Sqlite)
        {
            return "NUMERIC";
        }

        if (shape.Precision is not { } precision)
        {
            return fallback;
        }

        precision = Math.Clamp(precision, 1, maxPrecision);
        var scale = Math.Clamp(shape.Scale ?? 0, 0, precision);
        var name = family == TypeFamily.Oracle ? "NUMBER" : family == TypeFamily.PostgreSql ? "NUMERIC" : "DECIMAL";
        return string.Create(CultureInfo.InvariantCulture, $"{name}({precision},{scale})");
    }

    private static (string Type, CopyTypeApproximation? Approximation) TextType(SqlTypeShape shape, TypeFamily family, bool keyed, string unbounded)
    {
        var length = shape.Length;
        var fixedLength = shape.IsFixedLength && length is not null;
        switch (family)
        {
            case TypeFamily.PostgreSql:
                return (length is { } n ? Sized(fixedLength ? "CHAR" : "VARCHAR", n) : "TEXT", null);
            case TypeFamily.MySql:
                // A key on TEXT needs a prefix length, so a keyed unbounded column becomes VARCHAR(255).
                if (length is { } m && m <= (keyed ? 768 : 16_383))
                {
                    return (Sized(fixedLength && m <= 255 ? "CHAR" : "VARCHAR", m), null);
                }

                return keyed ? ("VARCHAR(255)", CopyTypeApproximation.CutTo255) : ("LONGTEXT", null);
            case TypeFamily.SqlServer:
                if (length is { } s && s <= 4_000)
                {
                    return (Sized(fixedLength ? "NCHAR" : "NVARCHAR", s), null);
                }

                return keyed ? ("NVARCHAR(450)", CopyTypeApproximation.CutTo450) : ("NVARCHAR(MAX)", null);
            case TypeFamily.Oracle:
                return length is { } o && o <= 4_000
                    ? (string.Create(CultureInfo.InvariantCulture, $"{(fixedLength ? "CHAR" : "VARCHAR2")}({o} CHAR)"), null)
                    : keyed ? ("VARCHAR2(4000 CHAR)", CopyTypeApproximation.CutTo4000) : ("CLOB", null);
            case TypeFamily.DuckDb:
                return ("VARCHAR", null);
            case TypeFamily.Sqlite:
                return ("TEXT", null);
            default:
                return (length is { } g ? Sized("VARCHAR", g) : unbounded, null);
        }
    }

    private static string BinaryType(SqlTypeShape shape, TypeFamily family) => family switch
    {
        TypeFamily.PostgreSql => "BYTEA",
        TypeFamily.MySql => shape.Length is { } m and <= 65_535 ? Sized(shape.IsFixedLength && m <= 255 ? "BINARY" : "VARBINARY", m) : "LONGBLOB",
        TypeFamily.SqlServer => shape.Length is { } s and <= 8_000 ? Sized(shape.IsFixedLength ? "BINARY" : "VARBINARY", s) : "VARBINARY(MAX)",
        TypeFamily.Oracle => shape.Length is { } o and <= 2_000 ? Sized("RAW", o) : "BLOB",
        _ => "BLOB",
    };

    private static string Sized(string name, int length) => string.Create(CultureInfo.InvariantCulture, $"{name}({Math.Max(1, length)})");

    /// <summary>
    /// A default another engine reads the same way: a number, a quoted string, NULL, TRUE or FALSE, or the current
    /// time. Anything else is an expression in the source's own SQL and is left out.
    /// </summary>
    public static string? PortableDefault(string? expression, SqlTypeShape shape, DatabaseEngine target)
    {
        ArgumentNullException.ThrowIfNull(shape);
        var text = expression?.Trim();
        if (string.IsNullOrEmpty(text))
        {
            return null;
        }

        // PostgreSQL writes 'x'::text and (0)::numeric, SQL Server ((0)) and ('x').
        var cast = text.LastIndexOf("::", StringComparison.Ordinal);
        if (cast > 0 && text.LastIndexOf('\'') < cast)
        {
            text = text[..cast].Trim();
        }

        while (text.Length >= 2 && text[0] == '(' && text[^1] == ')')
        {
            text = text[1..^1].Trim();
        }

        var dialect = SqlDialects.For(target);
        var upper = text.ToUpperInvariant();
        if (upper == "NULL")
        {
            return null;
        }

        if (upper is "CURRENT_TIMESTAMP" or "NOW()" or "GETDATE()" or "SYSDATETIME()" or "SYSDATE" or "SYSTIMESTAMP" or "LOCALTIMESTAMP" or "CURRENT_TIMESTAMP()" or "GETUTCDATE()"
            || upper.StartsWith("CURRENT_TIMESTAMP(", StringComparison.Ordinal) || upper.StartsWith("NOW(", StringComparison.Ordinal))
        {
            return shape.Category is SqlTypeCategory.Timestamp or SqlTypeCategory.Date ? "CURRENT_TIMESTAMP" : null;
        }

        if (shape.Category == SqlTypeCategory.Boolean && Truth(upper) is { } truth)
        {
            return FamilyOf(target) == TypeFamily.Oracle ? dialect.StringLiteral(truth ? "true" : "false") : dialect.BooleanLiteral(truth);
        }

        if (decimal.TryParse(text, NumberStyles.Float, CultureInfo.InvariantCulture, out var number))
        {
            return number.ToString(CultureInfo.InvariantCulture);
        }

        // N'x' and E'x' are prefixed string literals; the body is read and written again in the target's quoting.
        var body = text.Length > 1 && text[0] is 'N' or 'n' or 'E' or 'e' && text[1] == '\'' ? text[1..] : text;
        if (body.Length >= 2 && body[0] == '\'' && body[^1] == '\'')
        {
            var inner = body[1..^1];
            if (inner.Replace("''", string.Empty, StringComparison.Ordinal).Contains('\'', StringComparison.Ordinal))
            {
                return null;
            }

            return dialect.StringLiteral(inner.Replace("''", "'", StringComparison.Ordinal));
        }

        return null;
    }

    private static bool? Truth(string upper) => upper switch
    {
        "TRUE" or "'TRUE'" or "1" or "'1'" or "B'1'" or "'T'" => true,
        "FALSE" or "'FALSE'" or "0" or "'0'" or "B'0'" or "'F'" => false,
        _ => null,
    };
}
