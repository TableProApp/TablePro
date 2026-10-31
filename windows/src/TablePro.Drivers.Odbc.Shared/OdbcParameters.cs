using System.Data.Odbc;
using System.Globalization;
using System.Text;
using TablePro.Core.Sql;

namespace TablePro.Drivers.Odbc;

/// <summary>Command text with <c>?</c> markers and the values for them, in marker order.</summary>
internal readonly record struct OdbcStatement(string Text, IReadOnlyList<object?> Values);

/// <summary>
/// ODBC binds by position and only understands <c>?</c>. Core's builders write the dialect's own markers, so a
/// dialect with named markers (Oracle's <c>:p0</c>, which Dameng shares) is rewritten here: each marker becomes
/// <c>?</c> and its value is taken in the order the markers appear, so a name used twice binds twice.
/// </summary>
internal static class OdbcParameters
{
    public static bool IsPositional(SqlDialect dialect) => dialect.ParameterName(0) == "?";

    public static OdbcStatement Bind(SqlCommandSpec spec, SqlDialect dialect)
    {
        if (spec.Parameters.Count == 0)
        {
            return new(spec.Text, []);
        }

        if (IsPositional(dialect))
        {
            var values = new object?[spec.Parameters.Count];
            for (var i = 0; i < values.Length; i++)
            {
                values[i] = spec.Parameters[i].Value;
            }

            return new(spec.Text, values);
        }

        var named = new Dictionary<string, object?>(spec.Parameters.Count, StringComparer.Ordinal);
        foreach (var (name, value) in spec.Parameters)
        {
            named[name] = value;
        }

        var lookup = named.GetAlternateLookup<ReadOnlySpan<char>>();
        var text = spec.Text.AsSpan();
        var sql = new StringBuilder(text.Length);
        var bound = new List<object?>(spec.Parameters.Count);
        var lexer = new SqlLexer(text, dialect.LexerFeatures);
        while (lexer.TryRead(out var token))
        {
            var slice = token.Slice(text);

            // Only whole parameter tokens: :p10 is never read as :p1, and a string or quoted name holding the
            // marker's spelling is left alone.
            if (token.Kind == SqlTokenKind.Parameter && lookup.TryGetValue(slice, out var value))
            {
                sql.Append('?');
                bound.Add(value);
            }
            else
            {
                sql.Append(slice);
            }
        }

        return new(sql.ToString(), bound);
    }

    /// <summary>The statement with each <c>?</c> written as a literal, for the save review and the history.</summary>
    public static string Preview(OdbcStatement statement, SqlDialect dialect)
    {
        if (statement.Values.Count == 0)
        {
            return statement.Text;
        }

        var text = statement.Text.AsSpan();
        var sql = new StringBuilder(text.Length + (statement.Values.Count * 8));
        var next = 0;
        var lexer = new SqlLexer(text, dialect.LexerFeatures);
        while (lexer.TryRead(out var token))
        {
            var slice = token.Slice(text);
            if (token.Kind == SqlTokenKind.Parameter && slice is "?" && next < statement.Values.Count)
            {
                sql.Append(dialect.Literal(statement.Values[next++]));
            }
            else
            {
                sql.Append(slice);
            }
        }

        return sql.ToString();
    }

    public static OdbcCommand Command(OdbcConnection connection, string text, IReadOnlyList<object?> values)
    {
        var command = connection.CreateCommand();
        command.CommandText = text;
        foreach (var value in values)
        {
            command.Parameters.Add(Parameter(value));
        }

        return command;
    }

    /// <summary>
    /// A parameter for a value the grid or the filter produced. ODBC has no offset, date-only, time-only, GUID or
    /// unsigned SQL types, so those travel as the nearest type both engines convert from.
    /// </summary>
    public static OdbcParameter Parameter(object? value) => value switch
    {
        null or DBNull => new OdbcParameter { Value = DBNull.Value },
        DateOnly date => new OdbcParameter { OdbcType = OdbcType.Date, Value = date.ToDateTime(TimeOnly.MinValue) },
        TimeOnly time => new OdbcParameter { OdbcType = OdbcType.Time, Value = time.ToTimeSpan() },
        TimeSpan span => new OdbcParameter { OdbcType = OdbcType.Time, Value = span },
        DateTimeOffset offset => new OdbcParameter { Value = offset.ToString("yyyy-MM-dd HH:mm:ss.FFFFFFF zzz", CultureInfo.InvariantCulture) },
        Guid guid => new OdbcParameter { Value = guid.ToString() },
        char c => new OdbcParameter { Value = c.ToString() },
        sbyte s => new OdbcParameter { Value = (short)s },
        ushort u => new OdbcParameter { Value = (int)u },
        uint u => new OdbcParameter { Value = (long)u },
        ulong u => new OdbcParameter { Value = (decimal)u },
        _ => new OdbcParameter { Value = value },
    };
}
