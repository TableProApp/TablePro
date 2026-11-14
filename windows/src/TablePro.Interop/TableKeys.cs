using Native = TablePro.Interop.Native;

namespace TablePro.Interop;

// A table's foreign keys both ways, read once; what a row leads to is worked out from them without the server.
public sealed class TableKeys : IDisposable
{
    private readonly Native.TableKeys _keys;

    internal TableKeys(Native.TableKeys keys)
    {
        _keys = keys;
    }

    // From a row of a page of this table as the server holds it; column narrows the row's keys to those holding it.
    public RowReferences GetRowReferences(ResultSet rows, long row, string? column)
    {
        ArgumentNullException.ThrowIfNull(rows);
        ArgumentOutOfRangeException.ThrowIfNegative(row);
        var references = CoreCall.Run(() => _keys.RowReferences(rows.Handle, checked((ulong)row), column));
        return new RowReferences(
            [.. references.Referenced.Select(Mapping.Reference)],
            [.. references.Referencing.Select(Mapping.Reference)]);
    }

    public void Dispose() => _keys.Dispose();
}
