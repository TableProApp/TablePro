using Native = TablePro.Interop.Native;

namespace TablePro.Interop;

/// <summary>One result set of a run, held by the core and readable while its rows still arrive.</summary>
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

    /// <summary>True once the set holds every row it will.</summary>
    public bool IsFinished => _set.IsFinished();

    public IReadOnlyList<ResultColumn> GetColumns() => [.. _set.Columns().Select(Mapping.ResultColumn)];

    /// <summary>The whole value of one cell, for a detail pane or a copy. Null for SQL NULL.</summary>
    public string? GetCellText(long row, int column)
    {
        ArgumentOutOfRangeException.ThrowIfNegative(row);
        ArgumentOutOfRangeException.ThrowIfNegative(column);
        return CoreCall.Run(() => _set.CellText(checked((ulong)row), checked((uint)column)));
    }

    /// <summary>A cursor for <see cref="ResultCursor.Fetch"/>. Each thread that reads windows opens its own.</summary>
    public ResultCursor OpenCursor() => new(_set.OpenCursor());

    public void Dispose() => _set.Dispose();
}
