using Native = TablePro.Interop.Native;

namespace TablePro.Interop;

// A rendered grid copy: the text for the clipboard, the cells a paste reads back as they were, the type to offer
// beside plain text, and the row and skipped-value counts.
public sealed record GridCopy(string Text, string? Cells, string? MimeType, long Rows, long Skipped);

// A copy format that needs no SQL dialect; the dialect-bound formats are DatabaseSession's CopyResult methods.
public enum GridCopyFormat
{
    Tsv,
    TsvWithHeaders,
    Csv,
    CsvWithHeaders,
    Json,
    JsonLines,
    Markdown,
    TextTable,
}

internal static partial class Mapping
{
    public static GridCopy GridCopy(Native.GridCopy copy) =>
        new(copy.Text, copy.Cells, copy.MimeType, Count(copy.Rows), Count(copy.Skipped));

    public static Native.GridCopyFormat CopyFormat(GridCopyFormat format) => format switch
    {
        GridCopyFormat.Tsv => Native.GridCopyFormat.Tsv,
        GridCopyFormat.TsvWithHeaders => Native.GridCopyFormat.TsvWithHeaders,
        GridCopyFormat.Csv => Native.GridCopyFormat.Csv,
        GridCopyFormat.CsvWithHeaders => Native.GridCopyFormat.CsvWithHeaders,
        GridCopyFormat.Json => Native.GridCopyFormat.Json,
        GridCopyFormat.JsonLines => Native.GridCopyFormat.JsonLines,
        GridCopyFormat.Markdown => Native.GridCopyFormat.Markdown,
        GridCopyFormat.TextTable => Native.GridCopyFormat.TextTable,
        _ => throw new ArgumentOutOfRangeException(nameof(format)),
    };

    public static ulong[] RowIndices(IReadOnlyList<long> rows) => [.. rows.Select(row => checked((ulong)row))];

    public static uint[] ColumnIndices(IReadOnlyList<int> columns) => [.. columns.Select(column => checked((uint)column))];
}
