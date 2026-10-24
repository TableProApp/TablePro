#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum ShortcutOwner {
    BrowseTab,
    /// The browse tab's column view.
    BrowseGrid,
    /// A focused grid cell, through the grid's capture-phase controller.
    GridCell,
    /// A cell's open inline, multi-line or date editor.
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
