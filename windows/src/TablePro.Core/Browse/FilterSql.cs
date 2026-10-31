using System.Text;
using TablePro.Core.Sql;

namespace TablePro.Core.Browse;

/// <summary>Turns filter rules into a parameterized WHERE clause. Values are always bound, never spliced into the text.</summary>
internal static class FilterSql
{
    // '!' rather than a backslash, which MySQL would read as escaping the closing quote of the ESCAPE literal.
    private const string Escape = " ESCAPE '!'";

    public static string Render(SqlDialect dialect, FilterRule rule, IReadOnlyList<string> searchColumns, List<KeyValuePair<string, object?>> parameters)
    {
        if (!rule.Enabled)
        {
            return "1=1";
        }

        if (rule.Column is null)
        {
            return RenderSearch(dialect, searchColumns, rule.Value ?? string.Empty, parameters);
        }

        var column = dialect.QuoteIdentifier(rule.Column);
        return RenderColumn(dialect, column, rule, parameters);
    }

    private static string RenderSearch(SqlDialect dialect, IReadOnlyList<string> columns, string text, List<KeyValuePair<string, object?>> parameters)
    {
        if (columns.Count == 0 || string.IsNullOrEmpty(text))
        {
            return "1=1";
        }

        var name = Bind(dialect, parameters, "%" + EscapeLike(dialect, text) + "%");
        var sb = new StringBuilder("(");
        for (var i = 0; i < columns.Count; i++)
        {
            if (i > 0)
            {
                sb.Append(" OR ");
            }

            sb.Append(dialect.CastToText(dialect.QuoteIdentifier(columns[i]))).Append(' ').Append(dialect.CaseInsensitiveLike).Append(' ').Append(name).Append(Escape);
        }

        return sb.Append(')').ToString();
    }

    private static string RenderColumn(SqlDialect dialect, string column, FilterRule rule, List<KeyValuePair<string, object?>> parameters)
    {
        var value = rule.Value ?? string.Empty;
        var text = dialect.CastToText(column);
        var like = dialect.CaseInsensitiveLike;
        return rule.Operator switch
        {
            FilterOperator.Equals => $"{column} = {Bind(dialect, parameters, value)}",
            FilterOperator.NotEquals => $"{column} <> {Bind(dialect, parameters, value)}",
            FilterOperator.GreaterThan => $"{column} > {Bind(dialect, parameters, value)}",
            FilterOperator.GreaterOrEqual => $"{column} >= {Bind(dialect, parameters, value)}",
            FilterOperator.LessThan => $"{column} < {Bind(dialect, parameters, value)}",
            FilterOperator.LessOrEqual => $"{column} <= {Bind(dialect, parameters, value)}",
            FilterOperator.Contains => $"{text} {like} {Bind(dialect, parameters, "%" + EscapeLike(dialect, value) + "%")}{Escape}",
            FilterOperator.NotContains => $"{text} NOT {like} {Bind(dialect, parameters, "%" + EscapeLike(dialect, value) + "%")}{Escape}",
            FilterOperator.StartsWith => $"{text} {like} {Bind(dialect, parameters, EscapeLike(dialect, value) + "%")}{Escape}",
            FilterOperator.EndsWith => $"{text} {like} {Bind(dialect, parameters, "%" + EscapeLike(dialect, value))}{Escape}",
            FilterOperator.IsNull => $"{column} IS NULL",
            FilterOperator.IsNotNull => $"{column} IS NOT NULL",
            FilterOperator.IsEmpty => $"({column} IS NULL OR {text} = '')",
            FilterOperator.IsNotEmpty => $"({column} IS NOT NULL AND {text} <> '')",
            FilterOperator.In => $"{column} IN ({BindList(dialect, parameters, value)})",
            FilterOperator.NotIn => $"{column} NOT IN ({BindList(dialect, parameters, value)})",
            FilterOperator.Between => $"{column} BETWEEN {Bind(dialect, parameters, value)} AND {Bind(dialect, parameters, rule.SecondValue ?? string.Empty)}",
            _ => "1=1",
        };
    }

    private static string Bind(SqlDialect dialect, List<KeyValuePair<string, object?>> parameters, object? value)
    {
        var name = dialect.ParameterName(parameters.Count);
        parameters.Add(new(name, value));
        return name;
    }

    private static string BindList(SqlDialect dialect, List<KeyValuePair<string, object?>> parameters, string csv)
    {
        var items = csv.Split(',', StringSplitOptions.TrimEntries | StringSplitOptions.RemoveEmptyEntries);
        if (items.Length == 0)
        {
            return "NULL";
        }

        return string.Join(", ", items.Select(item => Bind(dialect, parameters, item)));
    }

    private static string EscapeLike(SqlDialect dialect, string value)
    {
        var wildcards = dialect.LikeWildcards;
        var sb = new StringBuilder(value.Length + 8);
        foreach (var c in value)
        {
            if (c == '!' || wildcards.Contains(c, StringComparison.Ordinal))
            {
                sb.Append('!');
            }

            sb.Append(c);
        }

        return sb.ToString();
    }
}
