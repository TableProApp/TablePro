namespace TablePro.Interop;

// What the engine keeps about a table besides its columns: each figure null where it keeps none or the login cannot
// read it.
public sealed record TableInfo(RowEstimate? Rows, string? Comment, long? DataBytes, long? IndexBytes, long? TotalBytes);
