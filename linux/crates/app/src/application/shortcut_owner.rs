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
    StructureTab,
    FilterStrip,
    /// A row of the sidebar's table list.
    SidebarList,
    /// A row of the query history dialog.
    HistoryRow,
}
