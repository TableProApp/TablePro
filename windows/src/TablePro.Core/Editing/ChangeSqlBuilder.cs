using System.Text;
using TablePro.Core.Schema;
using TablePro.Core.Sql;

namespace TablePro.Core.Editing;

/// <summary>Builds the parameterized statements for a set of grid edits.</summary>
public static class ChangeSqlBuilder
{
    public static SqlCommandSpec Build(SqlDialect dialect, ObjectName table, RowChange change) => change switch
    {
        RowUpdate update => BuildUpdate(dialect, table, update),
        RowInsert insert => BuildInsert(dialect, table, insert),
        RowDelete delete => BuildDelete(dialect, table, delete),
        _ => throw new ArgumentOutOfRangeException(nameof(change)),
    };

    /// <summary>The statement as text with the values written as literals, for the preview and the history.</summary>
    public static string Preview(SqlDialect dialect, ObjectName table, RowChange change)
    {
        var spec = Build(dialect, table, change);
        var literals = spec.Parameters.ToDictionary(p => p.Key, p => dialect.Literal(p.Value), StringComparer.Ordinal);
        var lookup = literals.GetAlternateLookup<ReadOnlySpan<char>>();
        var text = spec.Text.AsSpan();
        var sb = new StringBuilder(text.Length + (literals.Count * 8));

        // One pass over whole parameter tokens: @p10 is never read as @p1, and a value or quoted name that
        // happens to contain a parameter name is never rewritten.
        var lexer = new SqlLexer(text, dialect.LexerFeatures);
        while (lexer.TryRead(out var token))
        {
            var slice = token.Slice(text);
            if (token.Kind == SqlTokenKind.Parameter && lookup.TryGetValue(slice, out var literal))
            {
                sb.Append(literal);
            }
            else
            {
                sb.Append(slice);
            }
        }

        return sb.ToString();
    }

    private static SqlCommandSpec BuildUpdate(SqlDialect dialect, ObjectName table, RowUpdate update)
    {
        var parameters = new List<KeyValuePair<string, object?>>();
        var sql = new StringBuilder("UPDATE ").Append(dialect.Qualify(table)).Append(" SET ");
        var first = true;
        foreach (var (column, value) in update.Values)
        {
            if (!first)
            {
                sql.Append(", ");
            }

            sql.Append(dialect.QuoteIdentifier(column)).Append(" = ").Append(Bind(dialect, parameters, value));
            first = false;
        }

        AppendKey(dialect, sql, update.Key, parameters);
        return new SqlCommandSpec(sql.ToString(), parameters);
    }

    private static SqlCommandSpec BuildInsert(SqlDialect dialect, ObjectName table, RowInsert insert)
    {
        var parameters = new List<KeyValuePair<string, object?>>();
        var sql = new StringBuilder("INSERT INTO ").Append(dialect.Qualify(table));
        if (insert.Values.Count == 0)
        {
            return new SqlCommandSpec(sql.Append(" DEFAULT VALUES").ToString(), parameters);
        }

        sql.Append(" (").AppendJoin(", ", insert.Values.Keys.Select(dialect.QuoteIdentifier)).Append(") VALUES (");
        sql.AppendJoin(", ", insert.Values.Values.Select(v => Bind(dialect, parameters, v))).Append(')');
        return new SqlCommandSpec(sql.ToString(), parameters);
    }

    private static SqlCommandSpec BuildDelete(SqlDialect dialect, ObjectName table, RowDelete delete)
    {
        var parameters = new List<KeyValuePair<string, object?>>();
        var sql = new StringBuilder("DELETE FROM ").Append(dialect.Qualify(table));
        AppendKey(dialect, sql, delete.Key, parameters);
        return new SqlCommandSpec(sql.ToString(), parameters);
    }

    private static void AppendKey(SqlDialect dialect, StringBuilder sql, IReadOnlyDictionary<string, object?> key, List<KeyValuePair<string, object?>> parameters)
    {
        if (key.Count == 0)
        {
            throw new InvalidOperationException("A row needs at least one key column to be changed safely.");
        }

        sql.Append(" WHERE ");
        var first = true;
        foreach (var (column, value) in key)
        {
            if (!first)
            {
                sql.Append(" AND ");
            }

            var quoted = dialect.QuoteIdentifier(column);
            sql.Append(value is null ? $"{quoted} IS NULL" : $"{quoted} = {Bind(dialect, parameters, value)}");
            first = false;
        }
    }

    private static string Bind(SqlDialect dialect, List<KeyValuePair<string, object?>> parameters, object? value)
    {
        var name = dialect.ParameterName(parameters.Count);
        parameters.Add(new(name, value));
        return name;
    }
}
