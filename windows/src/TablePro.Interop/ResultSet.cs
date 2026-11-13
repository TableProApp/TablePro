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

    internal Native.ResultSet Handle => _set;

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

    // After the connection's rules were saved: masks the held rows of each column they now mask, unless the tab
    // revealed this run. True when a column changed, so the grid reads its cells and GetColumns again.
    public Task<bool> RemaskAsync() => CoreCall.RunAsync(() => _set.Remask());

    // The share sheet's columns as it starts them, from the first visibleColumns columns and the rows a share of
    // maxRows sends: the style the rules mask each with on the way out, else what the detectors saw.
    public async Task<IReadOnlyList<ShareColumnMasking>> GetShareMaskingAsync(int visibleColumns, long maxRows)
    {
        ArgumentOutOfRangeException.ThrowIfNegative(visibleColumns);
        ArgumentOutOfRangeException.ThrowIfNegative(maxRows);
        var limit = (uint)Math.Min(maxRows, uint.MaxValue);
        var columns = await CoreCall.RunAsync(() => _set.ShareMasking(checked((uint)visibleColumns), limit))
            .ConfigureAwait(false);
        return [.. columns.Select(Mapping.ColumnMasking)];
    }

    // What a share of maxRows with the sheet's choices sends, without building it: cheap enough for each choice.
    public async Task<ShareSummary> GetShareSummaryAsync(
        int visibleColumns, long maxRows, IReadOnlyList<ShareColumnChoice> columns)
    {
        ArgumentOutOfRangeException.ThrowIfNegative(visibleColumns);
        ArgumentOutOfRangeException.ThrowIfNegative(maxRows);
        ArgumentNullException.ThrowIfNull(columns);
        var limit = (uint)Math.Min(maxRows, uint.MaxValue);
        Native.ShareColumnChoice[] choices = [.. columns.Select(Mapping.Choice)];
        var summary = await CoreCall.RunAsync(
                () => _set.ShareSummary(checked((uint)visibleColumns), limit, choices))
            .ConfigureAwait(false);
        return Mapping.Summary(summary);
    }

    // The rows a share of maxRows with the sheet's choices sends, as a finished set: removed columns left out and
    // every value masked as the link's, so the preview shows a Stable Hash the core computed.
    public async Task<ResultSet> GetSharePreviewAsync(
        int visibleColumns, long maxRows, IReadOnlyList<ShareColumnChoice> columns)
    {
        ArgumentOutOfRangeException.ThrowIfNegative(visibleColumns);
        ArgumentOutOfRangeException.ThrowIfNegative(maxRows);
        ArgumentNullException.ThrowIfNull(columns);
        var limit = (uint)Math.Min(maxRows, uint.MaxValue);
        Native.ShareColumnChoice[] choices = [.. columns.Select(Mapping.Choice)];
        var preview = await CoreCall.RunAsync(
                () => _set.SharePreview(checked((uint)visibleColumns), limit, choices))
            .ConfigureAwait(false);
        return new ResultSet(preview, Index);
    }

    // For a statement that cannot run again: a new set over the rows held, sorted stably; this one keeps its order.
    public Task<ResultSet> SortedAsync(int column, bool ascending)
    {
        ArgumentOutOfRangeException.ThrowIfNegative(column);
        return CoreCall.RunAsync(() =>
            Task.FromResult(new ResultSet(_set.Sorted(checked((uint)column), ascending), Index)));
    }

    public void Dispose() => _set.Dispose();
}
