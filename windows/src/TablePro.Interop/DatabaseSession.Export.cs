using Native = TablePro.Interop.Native;

namespace TablePro.Interop;

// A file appears whole or not at all: the core writes beside it and renames once the last row is in.
public sealed partial class DatabaseSession
{
    private static readonly TimeSpan ProgressInterval = TimeSpan.FromMilliseconds(250);

    // Only the first visibleColumns columns, since a table page carries row addresses after them. SqlInsert with no
    // table writes into query_results, as the macOS app names a query result's table.
    public async Task<long> ExportRowsAsync(
        ResultSet rows,
        int visibleColumns,
        ExportFormat format,
        TableName? table,
        string path,
        IProgress<long>? progress = null,
        CancellationToken cancellationToken = default)
    {
        ArgumentNullException.ThrowIfNull(rows);
        ArgumentOutOfRangeException.ThrowIfNegative(visibleColumns);
        ArgumentException.ThrowIfNullOrEmpty(path);
        var target = table is null ? null : Mapping.Table(table);
        using var counter = new Native.ExportProgress();
        var written = await Reporting(
                counter,
                progress,
                CoreCall.RunAsync(
                    token => Handle.ExportRows(
                        rows.Handle,
                        checked((uint)visibleColumns),
                        NativeFormat(format),
                        target,
                        path,
                        counter,
                        token),
                    cancellationToken))
            .ConfigureAwait(false);
        return Mapping.Count(written);
    }

    // Every row the filter selects, in the sort's order, read on a connection of its own.
    public async Task<long> ExportTableAsync(
        TableName table,
        ColumnSort? sort,
        TableFilter? filter,
        ExportFormat format,
        string path,
        IProgress<long>? progress = null,
        CancellationToken cancellationToken = default)
    {
        ArgumentNullException.ThrowIfNull(table);
        ArgumentException.ThrowIfNullOrEmpty(path);
        var nativeSort = sort is null ? null : new Native.ColumnSort(checked((uint)sort.Column), sort.Ascending);
        var nativeFilter = filter is null ? null : Mapping.Filter(filter);
        using var counter = new Native.ExportProgress();
        var written = await Reporting(
                counter,
                progress,
                CoreCall.RunAsync(
                    token => Handle.ExportTable(
                        Mapping.Table(table),
                        nativeSort,
                        nativeFilter,
                        NativeFormat(format),
                        path,
                        counter,
                        token),
                    cancellationToken))
            .ConfigureAwait(false);
        return Mapping.Count(written);
    }

    // The core counts the rows as it writes them, and the count is read a few times a second until the export ends.
    private static async Task<ulong> Reporting(Native.ExportProgress counter, IProgress<long>? progress, Task<ulong> export)
    {
        if (progress is null)
        {
            return await export.ConfigureAwait(false);
        }

        using var timer = new PeriodicTimer(ProgressInterval);
        var reported = -1L;
        while (!export.IsCompleted)
        {
            var tick = timer.WaitForNextTickAsync().AsTask();
            await Task.WhenAny(export, tick).ConfigureAwait(false);
            var rows = Mapping.Count(counter.Rows());
            if (rows != reported)
            {
                reported = rows;
                progress.Report(rows);
            }
        }

        return await export.ConfigureAwait(false);
    }

    private static Native.ExportFormatTag NativeFormat(ExportFormat format) => format switch
    {
        ExportFormat.Csv => Native.ExportFormatTag.Csv,
        ExportFormat.Json => Native.ExportFormatTag.Json,
        ExportFormat.Excel => Native.ExportFormatTag.Excel,
        ExportFormat.Markdown => Native.ExportFormatTag.Markdown,
        ExportFormat.Html => Native.ExportFormatTag.Html,
        ExportFormat.Xml => Native.ExportFormatTag.Xml,
        ExportFormat.SqlInsert => Native.ExportFormatTag.SqlInsert,
        _ => throw new ArgumentOutOfRangeException(nameof(format), format, "An export format the core does not know."),
    };
}
