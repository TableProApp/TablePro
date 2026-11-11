using Microsoft.UI.Xaml.Controls;
using TablePro.App.Model;
using TablePro.DataGrid;
using TablePro.Editor;

namespace TablePro.App.Views;

// A tab's content in the strip; its run, close and transaction are its model's (QueryTab, TableTab).
internal interface ITabContent : IWorkspaceTab
{
    event EventHandler? StateChanged;

    SqlEditor? Editor { get; }

    DataGridView Grid { get; }

    // Copy and Select All reach the grid when it, not the editor, had focus last.
    bool GridIsTarget { get; }

    // Copy and Select All reach the run's messages while they are shown and had focus last.
    TextBox? MessagesTarget { get; }

    void Run();

    void Stop();

    void FocusContent();
}
