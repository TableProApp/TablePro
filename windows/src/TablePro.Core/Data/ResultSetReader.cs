using System.Data.Common;
using TablePro.Core.Results;

namespace TablePro.Core.Data;

/// <summary>Reads a provider's result into a <see cref="ResultSet"/>, stopping at the row limit.</summary>
public static class ResultSetReader
{
    public static async Task<ResultSet> ReadAsync(DbDataReader reader, int rowLimit, CancellationToken cancellationToken)
    {
        var fieldCount = reader.FieldCount;
        var columns = new ResultColumn[fieldCount];
        for (var i = 0; i < fieldCount; i++)
        {
            columns[i] = new ResultColumn(
                reader.GetName(i),
                SafeTypeName(reader, i),
                SafeFieldType(reader, i));
        }

        var rows = new List<object?[]>(Math.Min(rowLimit, 1024));
        var truncated = false;
        while (await reader.ReadAsync(cancellationToken))
        {
            if (rows.Count >= rowLimit)
            {
                truncated = true;
                break;
            }

            rows.Add(ReadRow(reader, fieldCount));
        }

        return new ResultSet(columns, rows, truncated);
    }

    public static object?[] ReadRow(DbDataReader reader, int fieldCount)
    {
        var values = new object?[fieldCount];
        try
        {
            reader.GetValues(values!);
        }
        catch (Exception ex) when (ex is InvalidCastException or OverflowException or FormatException or NotSupportedException or InvalidOperationException)
        {
            // One value the provider cannot map (a zero MySQL date, an exotic PostgreSQL type) must not lose the row.
            for (var i = 0; i < fieldCount; i++)
            {
                values[i] = ReadValueLeniently(reader, i);
            }
        }

        for (var i = 0; i < values.Length; i++)
        {
            if (values[i] is DBNull)
            {
                values[i] = null;
            }
        }

        return values;
    }

    private static object? ReadValueLeniently(DbDataReader reader, int ordinal)
    {
        try
        {
            return reader.IsDBNull(ordinal) ? null : reader.GetValue(ordinal);
        }
        catch (Exception ex) when (ex is InvalidCastException or OverflowException or FormatException or NotSupportedException or InvalidOperationException)
        {
            try
            {
                return reader.GetString(ordinal);
            }
            catch (Exception inner) when (inner is InvalidCastException or NotSupportedException or InvalidOperationException)
            {
                return $"<{ex.Message}>";
            }
        }
    }

    private static string SafeTypeName(DbDataReader reader, int ordinal)
    {
        try
        {
            return reader.GetDataTypeName(ordinal);
        }
        catch (Exception ex) when (ex is NotSupportedException or InvalidOperationException or InvalidCastException)
        {
            return "unknown";
        }
    }

    private static Type SafeFieldType(DbDataReader reader, int ordinal)
    {
        try
        {
            return reader.GetFieldType(ordinal) ?? typeof(object);
        }
        catch (Exception ex) when (ex is NotSupportedException or InvalidOperationException or InvalidCastException)
        {
            return typeof(object);
        }
    }
}
