using TablePro.Interop;

namespace TablePro.App.Model;

public enum ExportScope
{
    // A query tab's result as the grid holds it.
    ShownRows,
    CurrentPage,
    EntireTable,
}

// What a tab can export, each list in the order the dialog offers it.
public sealed class ExportPlan
{
    private const string RefusedInFileName = "<>:\"/\\|?*";

    private ExportPlan(IReadOnlyList<ExportScope> scopes, IReadOnlyList<ExportFormat> formats, string fileName)
    {
        Scopes = scopes;
        Formats = formats;
        FileName = fileName;
    }

    public IReadOnlyList<ExportScope> Scopes { get; }

    public IReadOnlyList<ExportFormat> Formats { get; }

    // Without an extension: the save picker adds the one of the format chosen.
    public string FileName { get; }

    // A query result's SQL INSERT writes into query_results, as macOS names it.
    public static ExportPlan For(TableName? table, string resultsName)
    {
        ArgumentNullException.ThrowIfNull(resultsName);
        ExportFormat[] formats =
        [
            ExportFormat.Csv,
            ExportFormat.Json,
            ExportFormat.Excel,
            ExportFormat.Markdown,
            ExportFormat.Html,
            ExportFormat.Xml,
            ExportFormat.SqlInsert,
        ];
        return table is null
            ? new ExportPlan([ExportScope.ShownRows], formats, resultsName)
            : new ExportPlan(
                [ExportScope.CurrentPage, ExportScope.EntireTable],
                formats,
                FileNameOf(table.Name, resultsName));
    }

    public static string Extension(ExportFormat format) => format switch
    {
        ExportFormat.Csv => ".csv",
        ExportFormat.Json => ".json",
        ExportFormat.Excel => ".xlsx",
        ExportFormat.Markdown => ".md",
        ExportFormat.Html => ".html",
        ExportFormat.Xml => ".xml",
        ExportFormat.SqlInsert => ".sql",
        _ => throw new ArgumentOutOfRangeException(nameof(format), format, null),
    };

    // Windows refuses these characters in a file name, and drops a dot or a space at its end.
    private static string FileNameOf(string table, string fallback)
    {
        var safe = table.Select(c => char.IsControl(c) || RefusedInFileName.Contains(c) ? '_' : c).ToArray();
        var name = new string(safe).TrimEnd('.', ' ');
        return string.IsNullOrWhiteSpace(name) ? fallback : name;
    }
}
