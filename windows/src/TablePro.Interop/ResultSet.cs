using Native = TablePro.Interop.Native;

namespace TablePro.Interop;

// Held by the core and readable while its rows still arrive.
public sealed class ResultSet : IDisposable
{
    private readonly Native.ResultSet _set;

    internal ResultSet(Native.ResultSet set, int index)
    {
        _set = set;
        Index = index;
    }

    public int Index { get; }

    public long RowCount => Mapping.Count(_set.RowCount());

    public bool IsFinished => _set.IsFinished();

    public IReadOnlyList<ResultColumn> GetColumns() => [.. _set.Columns().Select(Mapping.ResultColumn)];

    // The whole value, for a detail pane or a copy. Null for SQL NULL.
    public string? GetCellText(long row, int column)
    {
        ArgumentOutOfRangeException.ThrowIfNegative(row);
        ArgumentOutOfRangeException.ThrowIfNegative(column);
        return CoreCall.Run(() => _set.CellText(checked((ulong)row), checked((uint)column)));
    }

    // Each thread that reads windows opens its own.
    public ResultCursor OpenCursor() => new(_set.OpenCursor());

    // For a statement that cannot run again: a new set over the rows held, sorted stably; this one keeps its order.
    public Task<ResultSet> SortedAsync(int column, bool ascending)
    {
        ArgumentOutOfRangeException.ThrowIfNegative(column);
        return CoreCall.RunAsync(() =>
            Task.FromResult(new ResultSet(_set.Sorted(checked((uint)column), ascending), Index)));
    }

    public void Dispose() => _set.Dispose();
}
