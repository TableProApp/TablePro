using System.Globalization;
using System.Text;

namespace TablePro.Core.Sql;

/// <summary>A placeholder the editor asks a value for before a run: <c>?</c>, <c>:name</c> or <c>$1</c>.</summary>
public readonly record struct SqlParameter(string Name, int Start, int Length);

/// <summary>
/// Finds the placeholders in statements and writes the values the user typed into them as literals, so the history and
/// Safe Mode show the statement exactly as it ran. <c>@name</c> is left alone: in T-SQL and MySQL it is a variable.
/// </summary>
public static class SqlParameters
{
    public static IReadOnlyList<SqlParameter> Find(string sql, SqlDialect dialect)
    {
        if (!dialect.IsSql)
        {
            return [];
        }

        var found = new List<SqlParameter>();
        var span = sql.AsSpan();
        var lexer = new SqlLexer(span, dialect.LexerFeatures);
        var positional = 0;
        while (lexer.TryRead(out var token))
        {
            if (token.Kind != SqlTokenKind.Parameter)
            {
                continue;
            }

            var text = token.Slice(span);
            if (text[0] == '@')
            {
                continue;
            }

            var name = text is "?" ? string.Create(CultureInfo.InvariantCulture, $"?{++positional}") : text.ToString();
            found.Add(new SqlParameter(name, token.Start, token.Length));
        }

        return found;
    }

    /// <summary>The distinct names across statements, in the order they first appear.</summary>
    public static IReadOnlyList<string> DistinctNames(IEnumerable<string> statements, SqlDialect dialect) =>
        statements.SelectMany(s => Find(s, dialect)).Select(p => p.Name).Distinct(StringComparer.Ordinal).ToArray();

    /// <summary>Replaces each placeholder with its value as a literal: numbers stay numbers, NULL stays NULL.</summary>
    public static string Substitute(string sql, SqlDialect dialect, IReadOnlyDictionary<string, string?> values)
    {
        var parameters = Find(sql, dialect);
        if (parameters.Count == 0)
        {
            return sql;
        }

        var sb = new StringBuilder(sql.Length + (parameters.Count * 8));
        var position = 0;
        foreach (var parameter in parameters)
        {
            sb.Append(sql, position, parameter.Start - position);
            sb.Append(values.TryGetValue(parameter.Name, out var value) ? Literal(value, dialect) : sql.Substring(parameter.Start, parameter.Length));
            position = parameter.Start + parameter.Length;
        }

        return sb.Append(sql, position, sql.Length - position).ToString();
    }

    private static string Literal(string? value, SqlDialect dialect)
    {
        if (value is null || value.Equals("NULL", StringComparison.OrdinalIgnoreCase))
        {
            return "NULL";
        }

        var trimmed = value.Trim();
        if (LooksNumeric(trimmed))
        {
            return trimmed;
        }

        return value.Equals("true", StringComparison.OrdinalIgnoreCase) || value.Equals("false", StringComparison.OrdinalIgnoreCase)
            ? dialect.BooleanLiteral(bool.Parse(value))
            : dialect.StringLiteral(value);
    }

    /// <summary>A number, but not a code with a leading zero such as a ZIP code, which must stay text.</summary>
    private static bool LooksNumeric(string text)
    {
        if (!decimal.TryParse(text, NumberStyles.Float, CultureInfo.InvariantCulture, out _))
        {
            return false;
        }

        var digits = text.TrimStart('-', '+');
        return !(digits.Length > 1 && digits[0] == '0' && digits[1] != '.');
    }
}
