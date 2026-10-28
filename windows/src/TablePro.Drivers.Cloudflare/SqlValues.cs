using System.Globalization;
using System.Text;
using System.Text.Json;
using TablePro.Core.Results;
using TablePro.Core.Sql;

namespace TablePro.Drivers.Cloudflare;

/// <summary>Turns JSON cells into the values a <see cref="ResultSet"/> holds, and values into D1 parameters.</summary>
internal static class SqlValues
{
    public static object? FromJson(JsonElement value) => value.ValueKind switch
    {
        JsonValueKind.Null or JsonValueKind.Undefined => null,
        JsonValueKind.String => value.GetString(),
        JsonValueKind.Number => value.TryGetInt64(out var integer) ? integer : value.GetDouble(),
        JsonValueKind.True => true,
        JsonValueKind.False => false,
        _ => value.GetRawText(),
    };

    /// <summary>
    /// The D1 API declares its parameters as strings, as the macOS driver sends them; SQLite's column affinity turns
    /// "42" back into an integer in an INTEGER column.
    /// </summary>
    public static void WriteD1Parameter(Utf8JsonWriter writer, object? value)
    {
        switch (value)
        {
            case null or DBNull:
                writer.WriteNullValue();
                break;
            case string text:
                writer.WriteStringValue(text);
                break;
            case bool flag:
                writer.WriteStringValue(flag ? "1" : "0");
                break;
            case byte[] bytes:
                writer.WriteStringValue(Convert.ToBase64String(bytes));
                break;
            case DateTime dateTime:
                writer.WriteStringValue(dateTime.ToString("yyyy-MM-dd HH:mm:ss.FFFFFFF", CultureInfo.InvariantCulture));
                break;
            case DateTimeOffset offset:
                writer.WriteStringValue(offset.ToString("yyyy-MM-dd HH:mm:ss.FFFFFFFzzz", CultureInfo.InvariantCulture));
                break;
            case double d:
                writer.WriteStringValue(d.ToString("R", CultureInfo.InvariantCulture));
                break;
            case float f:
                writer.WriteStringValue(f.ToString("R", CultureInfo.InvariantCulture));
                break;
            case IFormattable formattable:
                writer.WriteStringValue(formattable.ToString(null, CultureInfo.InvariantCulture));
                break;
            default:
                writer.WriteStringValue(value.ToString());
                break;
        }
    }

    /// <summary>
    /// A column's type from the values a page holds, since the HTTP APIs return no declared types. One text value
    /// makes the column text, and integers mixed with reals make it real.
    /// </summary>
    public static ResultColumn InferColumn(string name, List<object?[]> rows, int ordinal)
    {
        var sawInteger = false;
        var sawReal = false;
        var sawText = false;
        var sawOther = false;
        foreach (var row in rows)
        {
            switch (row[ordinal])
            {
                case null:
                    break;
                case long:
                    sawInteger = true;
                    break;
                case double:
                    sawReal = true;
                    break;
                case string:
                    sawText = true;
                    break;
                default:
                    sawOther = true;
                    break;
            }
        }

        return (sawInteger, sawReal, sawText, sawOther) switch
        {
            (true, false, false, false) => new ResultColumn(name, "INTEGER", typeof(long)),
            (_, true, false, false) => new ResultColumn(name, "REAL", typeof(double)),
            (false, false, true, false) => new ResultColumn(name, "TEXT", typeof(string)),
            (false, false, false, false) => new ResultColumn(name, string.Empty, typeof(string)),
            _ => new ResultColumn(name, string.Empty, typeof(object)),
        };
    }

    /// <summary>
    /// Rewrites the named parameters the shared builders emit (<c>@p0</c>) as SQLite's numbered <c>?1</c>, because D1
    /// only binds ordered parameters. Whole parameter tokens are replaced, so <c>@p10</c> is never read as <c>@p1</c> and
    /// a string holding <c>@p0</c> is left alone.
    /// </summary>
    public static (string Sql, List<object?> Values) ToPositional(SqlCommandSpec spec, SqlDialect dialect)
    {
        var values = new List<object?>(spec.Parameters.Count);
        if (spec.Parameters.Count == 0)
        {
            return (spec.Text, values);
        }

        var lookup = new Dictionary<string, object?>(spec.Parameters.Count, StringComparer.Ordinal);
        foreach (var (name, value) in spec.Parameters)
        {
            lookup[name] = value;
        }

        var assigned = new Dictionary<string, int>(StringComparer.Ordinal);
        var text = spec.Text.AsSpan();
        var sql = new StringBuilder(text.Length + 8);
        var lexer = new SqlLexer(text, dialect.LexerFeatures);
        while (lexer.TryRead(out var token))
        {
            var slice = token.Slice(text);
            if (token.Kind == SqlTokenKind.Parameter && lookup.TryGetValue(slice.ToString(), out var value))
            {
                var name = slice.ToString();
                if (!assigned.TryGetValue(name, out var position))
                {
                    values.Add(value);
                    position = values.Count;
                    assigned[name] = position;
                }

                sql.Append('?').Append(position.ToString(CultureInfo.InvariantCulture));
            }
            else
            {
                sql.Append(slice);
            }
        }

        return (sql.ToString(), values);
    }

    /// <summary>
    /// Writes each bound value as an escaped literal, for R2 SQL, whose API takes no parameters. Only the shared
    /// builders' own parameter tokens are replaced, with the dialect's quoting.
    /// </summary>
    public static string Inline(SqlCommandSpec spec, SqlDialect dialect)
    {
        if (spec.Parameters.Count == 0)
        {
            return spec.Text;
        }

        var literals = new Dictionary<string, string>(spec.Parameters.Count, StringComparer.Ordinal);
        foreach (var (name, value) in spec.Parameters)
        {
            literals[name] = dialect.Literal(value);
        }

        var text = spec.Text.AsSpan();
        var sql = new StringBuilder(text.Length + 16);
        var lexer = new SqlLexer(text, dialect.LexerFeatures);
        while (lexer.TryRead(out var token))
        {
            var slice = token.Slice(text);
            if (token.Kind == SqlTokenKind.Parameter && literals.TryGetValue(slice.ToString(), out var literal))
            {
                sql.Append(literal);
            }
            else
            {
                sql.Append(slice);
            }
        }

        return sql.ToString();
    }
}
