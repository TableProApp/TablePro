using System.Globalization;
using System.Text;
using TablePro.Core.Sql;

namespace TablePro.Drivers.ClickHouse;

/// <summary>
/// Core writes a ClickHouse parameter as the bare name <c>p0</c>, which the server reads as a column. ClickHouse binds
/// <c>{p0:Type}</c> placeholders, so the text is rewritten to them before it is sent.
/// </summary>
/// <remarks>
/// Every value is bound as <c>String</c>, as the macOS driver does: the server converts a String constant to the
/// column's type in comparisons, mutations and <c>INSERT ... SELECT</c>, and the grid hands every value over as text
/// anyway. A String parameter cannot hold NULL and would compare bytes as hex text, so NULL and byte arrays are written
/// as <c>NULL</c> and <c>unhex('...')</c> instead.
/// </remarks>
internal static class ClickHouseParameters
{
    public const string ParameterType = "String";

    public sealed record Bound(string Text, IReadOnlyList<KeyValuePair<string, string>> Parameters);

    public static Bound Rewrite(SqlCommandSpec spec)
    {
        if (spec.Parameters.Count == 0)
        {
            return new Bound(spec.Text, []);
        }

        var values = new Dictionary<string, object?>(spec.Parameters.Count, StringComparer.Ordinal);
        foreach (var (name, value) in spec.Parameters)
        {
            values[name] = value;
        }

        var lookup = values.GetAlternateLookup<ReadOnlySpan<char>>();
        var text = spec.Text.AsSpan();
        var sql = new StringBuilder(text.Length + (spec.Parameters.Count * 12));
        var bound = new List<KeyValuePair<string, string>>(spec.Parameters.Count);
        var previous = SqlTokenKind.Whitespace;

        // One pass over whole tokens: p10 is never read as p1, and a string or quoted name holding p0 is left alone.
        var lexer = new SqlLexer(text, ClickHouseDialect.Instance.LexerFeatures);
        while (lexer.TryRead(out var token))
        {
            var slice = token.Slice(text);
            // An @p0 parameter token is taken too, so the text binds the same if the dialect moves to names Core's
            // lexer reads as parameters.
            var isName = (token.Kind == SqlTokenKind.Word && previous != SqlTokenKind.Dot) || token.Kind == SqlTokenKind.Parameter;
            if (isName && lookup.TryGetValue(slice, out var value))
            {
                AppendValue(sql, slice.TrimStart('@').ToString(), value, bound);
            }
            else
            {
                sql.Append(slice);
            }

            if (!token.IsTrivia)
            {
                previous = token.Kind;
            }
        }

        return new Bound(sql.ToString(), bound);
    }

    /// <summary>The text ClickHouse reads a String parameter from.</summary>
    public static string ToText(object value) => value switch
    {
        string s => s,
        bool b => b ? "true" : "false",
        char c => c.ToString(),
        DateTime dt => dt.ToString(dt.TimeOfDay == TimeSpan.Zero ? "yyyy-MM-dd" : "yyyy-MM-dd HH:mm:ss.FFFFFFF", CultureInfo.InvariantCulture),
        DateTimeOffset dto => dto.UtcDateTime.ToString("yyyy-MM-dd HH:mm:ss.FFFFFFF", CultureInfo.InvariantCulture),
        DateOnly d => d.ToString("yyyy-MM-dd", CultureInfo.InvariantCulture),
        TimeOnly t => t.ToString("HH:mm:ss.FFFFFFF", CultureInfo.InvariantCulture),
        float f => f.ToString("R", CultureInfo.InvariantCulture),
        double d => d.ToString("R", CultureInfo.InvariantCulture),
        IFormattable formattable => formattable.ToString(null, CultureInfo.InvariantCulture),
        _ => Convert.ToString(value, CultureInfo.InvariantCulture) ?? string.Empty,
    };

    private static void AppendValue(StringBuilder sql, string name, object? value, List<KeyValuePair<string, string>> bound)
    {
        switch (value)
        {
            case null or DBNull:
                sql.Append("NULL");
                break;
            case byte[] bytes:
                sql.Append("unhex('").Append(Convert.ToHexString(bytes)).Append("')");
                break;
            default:
                sql.Append('{').Append(name).Append(':').Append(ParameterType).Append('}');
                if (!bound.Exists(p => p.Key == name))
                {
                    bound.Add(new(name, ToText(value)));
                }

                break;
        }
    }
}
