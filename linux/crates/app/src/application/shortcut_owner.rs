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
    /// The picker as a whole, its search included.
    PickerPage,
    /// The assistant's suggestion shown in the SQL editor.
    InlineSuggestion,
    /// The assistant pane's message field.
    AssistantComposer,
}
