namespace TablePro.App.Views;

// A tab whose grid menu offers Export results; the workspace that holds it asks for the format and the file.
internal interface IExportSource
{
    event EventHandler? ExportRequested;
}
