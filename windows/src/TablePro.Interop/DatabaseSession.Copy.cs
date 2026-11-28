namespace TablePro.Interop;

// Grid copies in the connected engine's SQL. The dialect-free formats are ResultSet.Copy.
public sealed partial class DatabaseSession
{
    // rows of result under columns as INSERT statements into schema.table.
    public GridCopy CopyResultAsInsert(
        ResultSet result, IReadOnlyList<long> rows, IReadOnlyList<int> columns, string? schema, string table)
    {
        ArgumentNullException.ThrowIfNull(result);
        ArgumentNullException.ThrowIfNull(rows);
        ArgumentNullException.ThrowIfNull(columns);
        ArgumentNullException.ThrowIfNull(table);
        var nativeRows = Mapping.RowIndices(rows);
        var nativeColumns = Mapping.ColumnIndices(columns);
        return Mapping.GridCopy(
            CoreCall.Run(() => _session.CopyResultAsInsert(result.Handle, nativeRows, nativeColumns, schema, table)));
    }

    // One column's values of rows as an IN list in the connected engine's spelling.
    public GridCopy CopyResultInClause(ResultSet result, IReadOnlyList<long> rows, int column)
    {
        ArgumentNullException.ThrowIfNull(result);
        ArgumentNullException.ThrowIfNull(rows);
        ArgumentOutOfRangeException.ThrowIfNegative(column);
        var nativeRows = Mapping.RowIndices(rows);
        return Mapping.GridCopy(
            CoreCall.Run(() => _session.CopyResultInClause(result.Handle, nativeRows, checked((uint)column))));
    }

    // Every value of rows under columns as one list of the connected engine's literals.
    public GridCopy CopyResultAsValues(ResultSet result, IReadOnlyList<long> rows, IReadOnlyList<int> columns)
    {
        ArgumentNullException.ThrowIfNull(result);
        ArgumentNullException.ThrowIfNull(rows);
        ArgumentNullException.ThrowIfNull(columns);
        var nativeRows = Mapping.RowIndices(rows);
        var nativeColumns = Mapping.ColumnIndices(columns);
        return Mapping.GridCopy(
            CoreCall.Run(() => _session.CopyResultAsValues(result.Handle, nativeRows, nativeColumns)));
    }
}
