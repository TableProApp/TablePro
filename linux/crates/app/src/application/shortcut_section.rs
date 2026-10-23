/// A section of the shortcuts dialog.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum ShortcutSection {
    General,
    Tabs,
    BrowseTable,
    DataGrid,
    SqlEditor,
    TableStructure,
    ErDiagram,
}
