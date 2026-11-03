using TablePro.App.Model;
using TablePro.DataGrid;
using TablePro.Editor;
using TablePro.Interop;

namespace TablePro.App.Views;

// What the window's commands reach in the front tab of a connection.
internal interface ITabContent
{
    event EventHandler? StateChanged;

    string Title { get; }

    bool IsRunning { get; }

    // The transaction the tab's own connection holds; the workspace names a held one over the other tabs.
    TransactionState Transaction { get; }

    SqlEditor? Editor { get; }

    DataGridView Grid { get; }

    // Copy and Select All reach the grid when it, not the editor, had focus last.
    bool GridIsTarget { get; }

    void Run();

    void Stop();

    void FocusContent();

    SessionTab Snapshot();

    Task CloseAsync();
}
