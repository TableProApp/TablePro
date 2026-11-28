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

    // Whether the tab's rows wrap long values, which View and the column headers' menu switch; null where they cannot.
    bool? WrapsText { get; }

    void SetWrapsText(bool wraps);

    // Copy and Select All reach the grid when it, not the editor, had focus last.
    bool GridIsTarget { get; }

    // The grid's own row-edit undo and redo (ADR 0068); false and a no-op where the tab has no editable grid.
    bool CanUndoEdit { get; }

    bool CanRedoEdit { get; }

    void UndoEdit();

    void RedoEdit();

    // Copy and Select All reach the run's messages or a definition's text while it is shown and had focus last.
    TextBox? MessagesTarget { get; }

    void Run();

    void Stop();

    void FocusContent();
}
