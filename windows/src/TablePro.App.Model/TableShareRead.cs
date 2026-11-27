using TablePro.Interop;

namespace TablePro.App.Model;

// A table share: the view's first rows, its SQL (null where the engine cannot write it) and the filter's row count.
public sealed class TableShareRead : IDisposable
{
    private readonly ITabRun _run;

    public TableShareRead(ITabRun run, int visibleColumns, string? viewSql, long totalRows)
    {
        ArgumentNullException.ThrowIfNull(run);
        _run = run;
        Rows = run.GetResultSet(0);
        VisibleColumns = visibleColumns;
        ViewSql = viewSql;
        TotalRows = totalRows;
    }

    public ResultSet? Rows { get; }

    // The columns past it are the row's address, which a share never sends.
    public int VisibleColumns { get; }

    public string? ViewSql { get; }

    public long TotalRows { get; }

    public void Dispose()
    {
        Rows?.Dispose();
        _run.Dispose();
    }
}
