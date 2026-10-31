using System.Text;
using TablePro.Core.Editing;
using TablePro.Core.Localization;
using TablePro.Core.Sql;
using TablePro.Drivers.Cassandra.Localization;

namespace TablePro.Drivers.Cassandra;

/// <summary>One CQL statement of a save with its bound values.</summary>
public sealed record CqlWrite(string Cql, object?[] Values);

/// <summary>
/// The statements a grid save runs, each naming its row by the whole primary key. Every value is bound as JSON text
/// through <c>fromJson()</c>, so the server converts it to the column's type, collections and user-defined types
/// included, and the driver never guesses a CLR type for a marker.
/// </summary>
public static class CqlSaveBuilder
{
    private static SqlDialect Dialect => CqlDialect.Instance;

    public static IReadOnlyList<CqlWrite> Build(CqlTableShape shape, IReadOnlyList<RowChange> changes)
    {
        if (shape.PrimaryKey.Count == 0)
        {
            throw new InvalidOperationException(CassandraStrings.Format("Cassandra/PrimaryKeyUnreadable", shape.Table));
        }

        // A counter changes only by increments, and counter updates may not share a logged batch with anything.
        if (shape.HasCounters)
        {
            throw new InvalidOperationException(CassandraStrings.Get("Cassandra/CounterColumns"));
        }

        var writes = new List<CqlWrite>(changes.Count);
        foreach (var change in changes)
        {
            switch (change)
            {
                case RowUpdate update when update.Values.Count > 0:
                    writes.Add(Update(shape, update));
                    break;
                case RowInsert insert:
                    writes.Add(Insert(shape, insert));
                    break;
                case RowDelete delete:
                    writes.Add(Delete(shape, delete));
                    break;
            }
        }

        return writes;
    }

    /// <summary>The JSON text <c>fromJson()</c> reads for a cell. A composite column's cell already holds JSON.</summary>
    public static string ToJsonArgument(object value, bool isComposite) =>
        isComposite && value is string json ? json : CqlCellMapper.ToJson(value);

    private static CqlWrite Update(CqlTableShape shape, RowUpdate update)
    {
        var values = new List<object?>();
        var sql = new StringBuilder("UPDATE ").Append(Dialect.Qualify(shape.Table)).Append(" SET ");
        var first = true;
        var onlyStatic = true;
        foreach (var (column, value) in update.Values)
        {
            var row = shape.Column(column) ?? throw new InvalidOperationException(CoreStrings.Format("Driver/TableHasNoColumn", shape.Table, column));
            if (row.IsPrimaryKey)
            {
                throw new InvalidOperationException(CassandraStrings.Format("Cassandra/CannotChangePrimaryKey", column));
            }

            onlyStatic &= row.IsStatic;
            sql.Append(first ? string.Empty : ", ").Append(Dialect.QuoteIdentifier(column));
            if (value is null)
            {
                sql.Append(" = null");
            }
            else
            {
                sql.Append(" = fromJson(?)");
                values.Add(ToJsonArgument(value, shape.IsComposite(column)));
            }

            first = false;
        }

        // A static column belongs to the partition, and CQL refuses clustering columns in an update of only static ones.
        AppendKey(sql, shape, onlyStatic ? shape.PartitionKey : shape.PrimaryKey, update.Key, values);
        return new CqlWrite(sql.ToString(), [.. values]);
    }

    private static CqlWrite Insert(CqlTableShape shape, RowInsert insert)
    {
        foreach (var key in shape.PrimaryKey)
        {
            if (!insert.Values.TryGetValue(key, out var value) || value is null)
            {
                throw new InvalidOperationException(CassandraStrings.Format("Cassandra/EnterPrimaryKeyValue", key));
            }
        }

        var names = new List<string>();
        var values = new List<object?>();
        foreach (var (column, value) in insert.Values)
        {
            // An absent cell reads as NULL without the tombstone a written NULL leaves behind.
            if (value is null)
            {
                continue;
            }

            if (shape.Column(column) is null)
            {
                throw new InvalidOperationException(CoreStrings.Format("Driver/TableHasNoColumn", shape.Table, column));
            }

            names.Add(Dialect.QuoteIdentifier(column));
            values.Add(ToJsonArgument(value, shape.IsComposite(column)));
        }

        var sql = new StringBuilder("INSERT INTO ").Append(Dialect.Qualify(shape.Table))
            .Append(" (").AppendJoin(", ", names).Append(") VALUES (")
            .AppendJoin(", ", Enumerable.Repeat("fromJson(?)", names.Count)).Append(')');
        return new CqlWrite(sql.ToString(), [.. values]);
    }

    private static CqlWrite Delete(CqlTableShape shape, RowDelete delete)
    {
        var values = new List<object?>();
        var sql = new StringBuilder("DELETE FROM ").Append(Dialect.Qualify(shape.Table));
        AppendKey(sql, shape, shape.PrimaryKey, delete.Key, values);
        return new CqlWrite(sql.ToString(), [.. values]);
    }

    private static void AppendKey(StringBuilder sql, CqlTableShape shape, IReadOnlyList<string> keyColumns, IReadOnlyDictionary<string, object?> key, List<object?> values)
    {
        sql.Append(" WHERE ");
        for (var i = 0; i < keyColumns.Count; i++)
        {
            var column = keyColumns[i];
            if (!key.TryGetValue(column, out var value) || value is null)
            {
                throw new InvalidOperationException(CassandraStrings.Format("Cassandra/PrimaryKeyNotLoaded", column));
            }

            sql.Append(i == 0 ? string.Empty : " AND ").Append(Dialect.QuoteIdentifier(column)).Append(" = fromJson(?)");
            values.Add(ToJsonArgument(value, shape.IsComposite(column)));
        }
    }
}
