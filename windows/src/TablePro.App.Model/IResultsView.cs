using TablePro.DataGrid.Model;
using TablePro.Interop;

namespace TablePro.App.Model;

// The results pane under a tab: it reads a run's events and owns the sets it shows.
public interface IResultsView
{
    // The grid shows a clicked sort at once, so a tab that does not run it sets this back.
    GridSort Sort { get; set; }

    IReadOnlyList<ResultColumn> Columns { get; }

    int ResultSetCount { get; }

    long RowCount { get; }

    // A sort of the rows held shows a copy, so its count is the shown set's, not the run's.
    long ShownRowCount { get; }

    TransactionState Transaction { get; }

    // Null from the start of each ShowRunAsync until its Finished arrives, so a run that never ends has none.
    QueryOutcome? Outcome { get; }

    // The counts the run's CommandCompleted events carried, summed; null when none carried one.
    long? RowsAffected { get; }

    ResultSet? ShownSet { get; }

    event EventHandler? ShownSetChanged;

    Task ShowRunAsync(ITabRun run, GridSort sort, int visibleColumns, CancellationToken cancellationToken);

    // False when no set is shown, or a run or a pick replaced it while the rows were being sorted.
    Task<bool> SortHeldRowsAsync(GridSort sort);

    void ShowError(CoreError failure);

    void Clear();
}
