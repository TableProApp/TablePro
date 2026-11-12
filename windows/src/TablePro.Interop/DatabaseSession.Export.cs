using Native = TablePro.Interop.Native;

namespace TablePro.Interop;

// A file appears whole or not at all: the core writes beside it and renames once the last row is in.
public sealed partial class DatabaseSession
{
    // Only the first visibleColumns columns, since a table page carries row addresses after them.
    public async Task<long> ExportRowsAsync(
        ResultSet rows,
        int visibleColumns,
        ExportFormat format,
        TableName? table,
        string path,
        CancellationToken cancellationToken = default)
    {
        ArgumentNullException.ThrowIfNull(rows);
        ArgumentOutOfRangeException.ThrowIfNegative(visibleColumns);
        ArgumentException.ThrowIfNullOrEmpty(path);
        var target = table is null ? null : Mapping.Table(table);
        var written = await CoreCall.RunAsync(
                token => Handle.ExportRows(
                    rows.Handle,
                    checked((uint)visibleColumns),
                    NativeFormat(format),
                    target,
                    path,
                    token),
                cancellationToken)
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
        CancellationToken cancellationToken = default)
    {
        ArgumentNullException.ThrowIfNull(table);
        ArgumentException.ThrowIfNullOrEmpty(path);
        var nativeSort = sort is null ? null : new Native.ColumnSort(checked((uint)sort.Column), sort.Ascending);
        var nativeFilter = filter is null ? null : Mapping.Filter(filter);
        var written = await CoreCall.RunAsync(
                token => Handle.ExportTable(
                    Mapping.Table(table),
                    nativeSort,
                    nativeFilter,
                    NativeFormat(format),
                    path,
                    token),
                cancellationToken)
            .ConfigureAwait(false);
        return Mapping.Count(written);
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
