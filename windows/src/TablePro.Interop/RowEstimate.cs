namespace TablePro.Interop;

// The engine's own idea of a table's rows, read from its statistics with no scan; exact where it keeps the count.
public sealed record RowEstimate(long Rows, bool IsExact);
