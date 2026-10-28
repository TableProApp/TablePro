using System.Text;
using TablePro.Core.Editing;
using TablePro.Core.Schema;
using TablePro.Core.Sql;

namespace TablePro.Drivers.ClickHouse;

/// <summary>
/// The statements a grid save becomes on ClickHouse, which has no UPDATE, no DELETE that reports a row count and no
/// transaction. An edit is an <c>ALTER TABLE ... UPDATE</c> mutation, a delete an <c>ALTER TABLE ... DELETE</c>
/// mutation, and a new row an <c>INSERT ... SELECT</c>, whose SELECT casts each String parameter to the column's type.
/// Rows are found by the key the structure reports: the table's ORDER BY and PRIMARY KEY columns.
/// </summary>
/// <remarks>
/// A mutation is asynchronous on the server: it is queued and rewrites whole parts in the background. The session
/// sends each one with <c>mutations_sync=1</c> so the save returns once its mutation has finished on the replica it
/// reached, and the grid's refetch shows what it wrote. Without a transaction a save that fails part-way leaves the
/// statements before the failure applied, so every row a mutation will touch is counted first and nothing is sent
/// unless each count is exactly one.
/// </remarks>
internal static class ClickHouseMutations
{
    private static SqlDialect Dialect => ClickHouseDialect.Instance;

    public static SqlCommandSpec Build(ObjectName table, RowChange change) => change switch
    {
        RowUpdate update => Update(table, update),
        RowInsert insert => Insert(table, insert),
        RowDelete delete => Delete(table, delete),
        _ => throw new ArgumentOutOfRangeException(nameof(change)),
    };

    /// <summary>The count that proves a keyed change reaches exactly one row, or null for an insert.</summary>
    public static SqlCommandSpec? Probe(ObjectName table, RowChange change)
    {
        var key = change switch
        {
            RowUpdate update => update.Key,
            RowDelete delete => delete.Key,
            _ => null,
        };

        if (key is null)
        {
            return null;
        }

        var parameters = new List<KeyValuePair<string, object?>>();
        var sql = new StringBuilder("SELECT count() FROM ").Append(Dialect.Qualify(table));
        AppendKey(sql, key, parameters);
        return new SqlCommandSpec(sql.ToString(), parameters);
    }

    /// <summary>
    /// A mutation refuses any column of the sorting, primary or partition key, even set to the value it holds. Checked
    /// before anything runs, so a save is refused whole instead of failing after earlier statements landed.
    /// </summary>
    public static void EnsureMutable(IReadOnlyList<RowChange> changes, IReadOnlyCollection<string> keyColumns)
    {
        if (keyColumns.Count == 0)
        {
            return;
        }

        var keys = new HashSet<string>(keyColumns, StringComparer.Ordinal);
        foreach (var change in changes)
        {
            if (change is not RowUpdate update)
            {
                continue;
            }

            foreach (var column in update.Values.Keys)
            {
                if (keys.Contains(column))
                {
                    throw new InvalidOperationException(
                        $"ClickHouse cannot change {column}, because it is part of the table's sorting, primary or partition key. Nothing was saved.");
                }
            }
        }
    }

    private static SqlCommandSpec Update(ObjectName table, RowUpdate update)
    {
        if (update.Values.Count == 0)
        {
            throw new InvalidOperationException("An update needs at least one changed column.");
        }

        var parameters = new List<KeyValuePair<string, object?>>();
        var sql = new StringBuilder("ALTER TABLE ").Append(Dialect.Qualify(table)).Append(" UPDATE ");
        var first = true;
        foreach (var (column, value) in update.Values)
        {
            if (!first)
            {
                sql.Append(", ");
            }

            sql.Append(Dialect.QuoteIdentifier(column)).Append(" = ").Append(Bind(parameters, value));
            first = false;
        }

        AppendKey(sql, update.Key, parameters);
        return new SqlCommandSpec(sql.ToString(), parameters);
    }

    private static SqlCommandSpec Delete(ObjectName table, RowDelete delete)
    {
        var parameters = new List<KeyValuePair<string, object?>>();
        var sql = new StringBuilder("ALTER TABLE ").Append(Dialect.Qualify(table)).Append(" DELETE");
        AppendKey(sql, delete.Key, parameters);
        return new SqlCommandSpec(sql.ToString(), parameters);
    }

    private static SqlCommandSpec Insert(ObjectName table, RowInsert insert)
    {
        // ClickHouse has no DEFAULT VALUES, and which column may take DEFAULT is not known here.
        if (insert.Values.Count == 0)
        {
            throw new InvalidOperationException("ClickHouse needs at least one value to insert a row.");
        }

        var parameters = new List<KeyValuePair<string, object?>>();
        var sql = new StringBuilder("INSERT INTO ").Append(Dialect.Qualify(table)).Append(" (");
        sql.AppendJoin(", ", insert.Values.Keys.Select(Dialect.QuoteIdentifier)).Append(") SELECT ");
        sql.AppendJoin(", ", insert.Values.Values.Select(v => Bind(parameters, v)));
        return new SqlCommandSpec(sql.ToString(), parameters);
    }

    private static void AppendKey(StringBuilder sql, IReadOnlyDictionary<string, object?> key, List<KeyValuePair<string, object?>> parameters)
    {
        if (key.Count == 0)
        {
            throw new InvalidOperationException("A row needs at least one key column to be changed safely. ClickHouse keys rows by the table's ORDER BY columns.");
        }

        sql.Append(" WHERE ");
        var first = true;
        foreach (var (column, value) in key)
        {
            if (!first)
            {
                sql.Append(" AND ");
            }

            var quoted = Dialect.QuoteIdentifier(column);
            sql.Append(value is null or DBNull ? $"{quoted} IS NULL" : $"{quoted} = {Bind(parameters, value)}");
            first = false;
        }
    }

    private static string Bind(List<KeyValuePair<string, object?>> parameters, object? value)
    {
        var name = Dialect.ParameterName(parameters.Count);
        parameters.Add(new(name, value));
        return name;
    }
}
