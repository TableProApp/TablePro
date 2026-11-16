namespace TablePro.Interop;

// SqlInsert writes the rows into the table they came from, or into query_results where no one table is known.
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
