#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum ShortcutOwner {
    BrowseTab,
    /// A data grid's column view, ahead of the list's own key bindings.
    GridCell,
    /// A data grid's column view, after a focused editor had its turn.
    Grid,
    /// A grid's inline editor, or its detail pane's value editor.
    CellEditor,
    /// The SQL editor's source view.
    SqlEditor,
    /// The SQL editor's other cursors. Not kept from Vim, whose mode turns
    /// them off and has Ctrl+D of its own.
    SqlEditorCursors,
    /// The whole SQL editor tab, its find bar included.
    SqlEditorTab,
    StructureTab,
    FilterStrip,
    /// A row of the sidebar's table list.
    SidebarList,
    /// A row of the window's connection tree.
    ConnectionTree,
    /// A row of the query history dialog.
    HistoryRow,
    /// A saved connection's row in the picker.
    PickerRow,
    /// The whole ER diagram tab, its bottom bar included.
    DiagramTab,
    /// The diagram's canvas, where a table has the keyboard focus.
    DiagramCanvas,
    /// The picker as a whole, its search included.
    PickerPage,
    /// The assistant's suggestion shown in the SQL editor.
    InlineSuggestion,
    /// The assistant pane's message field.
    AssistantComposer,
}
