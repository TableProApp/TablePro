using System.Globalization;
using System.Text;
using TablePro.Core.Browse;
using TablePro.Core.Schema;
using TablePro.Core.Sql;

namespace TablePro.Core.JoinBuilder;

/// <summary>
/// Writes the join builder's draft as one SELECT in the engine's dialect. Names go through
/// <see cref="SqlDialect.QuoteIdentifier"/> and <see cref="SqlDialect.Qualify"/>. The text opens in a query tab where
/// the user reads and runs it, so filter values are written as literals: a number only when the column is numeric
/// and the value parses as one, and otherwise an escaped string, never the raw text.
/// </summary>
public sealed class JoinQuerySqlWriter(SqlDialect dialect, string? schema)
{
    // '!' rather than a backslash, which MySQL would read as escaping the closing quote of the ESCAPE literal.
    private const string Escape = " ESCAPE '!'";

    public SqlDialect Dialect { get; } = dialect;

    /// <summary>The schema tables are qualified with; null leaves them to the connection's search path.</summary>
    public string? Schema { get; } = schema;

    /// <summary>The SELECT, or null when no table is picked.</summary>
    public string? Write(JoinQueryDraft draft, JoinGraph graph)
    {
        ArgumentNullException.ThrowIfNull(draft);
        ArgumentNullException.ThrowIfNull(graph);
        if (draft.Tables.Count == 0)
        {
            return null;
        }

        var sql = new StringBuilder("SELECT ");
        var first = true;
        foreach (var table in draft.Tables)
        {
            foreach (var column in table.SelectedColumns)
            {
                sql.Append(first ? string.Empty : ", ").Append(Column(table.Name, column));
                first = false;
            }
        }

        if (first)
        {
            sql.Append('*');
        }

        sql.Append("\nFROM ").Append(Source(draft.Tables[0].Name));
        for (var i = 1; i < draft.Tables.Count; i++)
        {
            var table = draft.Tables[i];
            if (table.Condition is not { } condition)
            {
                sql.Append("\nCROSS JOIN ").Append(Source(table.Name));
                continue;
            }

            sql.Append('\n').Append(table.Kind.Keyword()).Append(' ').Append(Source(table.Name)).Append(" ON ");
            for (var p = 0; p < condition.ColumnPairs.Count; p++)
            {
                var pair = condition.ColumnPairs[p];
                sql.Append(p > 0 ? " AND " : string.Empty)
                    .Append(Column(condition.ChildTable, pair.Child)).Append(" = ").Append(Column(condition.ParentTable, pair.Parent));
            }
        }

        var conditions = draft.Filters.Where(f => draft.Contains(f.Column.Table)).Select(f => Condition(f, graph)).OfType<string>().ToArray();
        if (conditions.Length > 0)
        {
            sql.Append("\nWHERE ").AppendJoin(" AND ", conditions);
        }

        var sorts = draft.Sorts.Where(s => draft.Contains(s.Column.Table)).ToArray();
        if (sorts.Length > 0)
        {
            sql.Append("\nORDER BY ").AppendJoin(", ", sorts.Select(s => Column(s.Column.Table, s.Column.Column) + (s.Descending ? " DESC" : " ASC")));
        }

        return sql.ToString();
    }

    private string Source(string table) => Dialect.Qualify(new ObjectName(string.IsNullOrEmpty(Schema) ? null : Schema, table));

    private string Column(string table, string column) => $"{Dialect.QuoteIdentifier(table)}.{Dialect.QuoteIdentifier(column)}";

    /// <summary>A filter that needs a value and has none is left out, as the filter strip leaves out an empty rule.</summary>
    private string? Condition(JoinFilter filter, JoinGraph graph)
    {
        var op = filter.Operator;
        var value = filter.Value.Trim();
        if (op.TakesValue() && value.Length == 0)
        {
            return null;
        }

        if (op == FilterOperator.Between && filter.SecondValue.Trim().Length == 0)
        {
            return null;
        }

        var column = Column(filter.Column.Table, filter.Column.Column);
        var numeric = IsNumericType(graph.TypeOf(filter.Column.Table, filter.Column.Column));
        var text = Dialect.CastToText(column);
        var like = Dialect.CaseInsensitiveLike;
        return op switch
        {
            FilterOperator.Equals => $"{column} = {Literal(value, numeric)}",
            FilterOperator.NotEquals => $"{column} <> {Literal(value, numeric)}",
            FilterOperator.GreaterThan => $"{column} > {Literal(value, numeric)}",
            FilterOperator.GreaterOrEqual => $"{column} >= {Literal(value, numeric)}",
            FilterOperator.LessThan => $"{column} < {Literal(value, numeric)}",
            FilterOperator.LessOrEqual => $"{column} <= {Literal(value, numeric)}",
            FilterOperator.Contains => $"{text} {like} {Dialect.StringLiteral("%" + EscapeLike(value) + "%")}{Escape}",
            FilterOperator.NotContains => $"{text} NOT {like} {Dialect.StringLiteral("%" + EscapeLike(value) + "%")}{Escape}",
            FilterOperator.StartsWith => $"{text} {like} {Dialect.StringLiteral(EscapeLike(value) + "%")}{Escape}",
            FilterOperator.EndsWith => $"{text} {like} {Dialect.StringLiteral("%" + EscapeLike(value))}{Escape}",
            FilterOperator.IsNull => $"{column} IS NULL",
            FilterOperator.IsNotNull => $"{column} IS NOT NULL",
            FilterOperator.IsEmpty => $"({column} IS NULL OR {text} = '')",
            FilterOperator.IsNotEmpty => $"({column} IS NOT NULL AND {text} <> '')",
            FilterOperator.In => $"{column} IN ({List(value, numeric)})",
            FilterOperator.NotIn => $"{column} NOT IN ({List(value, numeric)})",
            FilterOperator.Between => $"{column} BETWEEN {Literal(value, numeric)} AND {Literal(filter.SecondValue.Trim(), numeric)}",
            _ => null,
        };
    }

    private string List(string csv, bool numeric)
    {
        var items = csv.Split(',', StringSplitOptions.TrimEntries | StringSplitOptions.RemoveEmptyEntries);
        return items.Length == 0 ? "NULL" : string.Join(", ", items.Select(item => Literal(item, numeric)));
    }

    // The parsed number is written back, so text that merely starts like a number can never ride along.
    private string Literal(string value, bool numeric) =>
        numeric && decimal.TryParse(value, NumberStyles.Float, CultureInfo.InvariantCulture, out var number)
            ? number.ToString(CultureInfo.InvariantCulture)
            : Dialect.StringLiteral(value);

    private string EscapeLike(string value)
    {
        var wildcards = Dialect.LikeWildcards;
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

    /// <summary>Whether a declared type holds numbers, so a filter compares numbers rather than text.</summary>
    public static bool IsNumericType(string? dataType)
    {
        if (string.IsNullOrWhiteSpace(dataType))
        {
            return false;
        }

        var type = dataType.AsSpan().Trim();
        var paren = type.IndexOf('(');
        if (paren >= 0)
        {
            type = type[..paren].TrimEnd();
        }

        // A point is not a number, nor an interval; matching whole words keeps "interval" out of "int".
        Span<char> lower = stackalloc char[Math.Min(type.Length, 64)];
        var length = type[..lower.Length].ToLowerInvariant(lower);
        var name = lower[..length];
        return name switch
        {
            "int" or "integer" or "int2" or "int4" or "int8" or "smallint" or "bigint" or "tinyint" or "mediumint" or "serial" or "bigserial" or "smallserial"
                or "decimal" or "numeric" or "number" or "dec" or "real" or "float" or "float4" or "float8" or "double" or "double precision"
                or "money" or "smallmoney" or "binary_float" or "binary_double" or "hugeint" or "ubigint" or "uinteger" or "usmallint" or "utinyint"
                or "int unsigned" or "bigint unsigned" or "smallint unsigned" or "tinyint unsigned" or "mediumint unsigned" or "int64" or "float64" => true,
            _ => false,
        };
    }
}
