namespace TablePro.Interop;

// SqlInsert writes a table's rows into that table and a query result's into query_results.
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
