using Microsoft.UI.Xaml.Controls;
using TablePro.App.Model;
using TablePro.DataGrid;
using TablePro.Editor;

namespace TablePro.App.Views;

// A tab's content in the strip; its run, close and transaction are its model's (QueryTab, TableTab, DefinitionTab).
internal interface ITabContent : IWorkspaceTab
{
    event EventHandler? StateChanged;

    SqlEditor? Editor { get; }

    // A definition tab shows text, not rows.
    DataGridView? Grid { get; }

    // Copy and Select All reach the grid when it, not the editor, had focus last.
    bool GridIsTarget { get; }

    // Copy and Select All reach the run's messages or a definition's text while it is shown and had focus last.
    TextBox? MessagesTarget { get; }

    void Run();

    void Stop();

    void FocusContent();

    // The connection's masking rules were saved: rows on screen take them now.
    void Remask();
}
