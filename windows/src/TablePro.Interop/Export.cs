namespace TablePro.Interop;

// SqlInsert writes the rows back into the table they came from, so it needs that table.
public enum ExportFormat
{
    Csv,
    Json,
    Excel,
    Markdown,
    Html,
    Xml,
    SqlInsert,
}
