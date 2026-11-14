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

    // From a row of a page of this table; column narrows the row's own keys to those holding it. Reads only
    // whether each key's cells hold a value, so a menu copies none.
    public RowReferences GetRowReferences(ResultSet rows, long row, string? column)
    {
        ArgumentNullException.ThrowIfNull(rows);
        ArgumentOutOfRangeException.ThrowIfNegative(row);
        var references = CoreCall.Run(() => _keys.RowReferences(rows.Handle, checked((ulong)row), column));
        return new RowReferences(
            [.. references.Referenced.Select(Mapping.Reference)],
            [.. references.Referencing.Select(Mapping.Reference)]);
    }

    // The filter of a key GetRowReferences offered for the same row, built from the row as the server holds it.
    public FollowedReference Follow(ResultSet rows, long row, RowReferenceChoice choice)
    {
        ArgumentNullException.ThrowIfNull(rows);
        ArgumentNullException.ThrowIfNull(choice);
        ArgumentOutOfRangeException.ThrowIfNegative(row);
        return Mapping.Followed(CoreCall.Run(() =>
            _keys.FollowReference(rows.Handle, checked((ulong)row), choice.Referencing, checked((uint)choice.Key))));
    }

    public void Dispose() => _keys.Dispose();
}
