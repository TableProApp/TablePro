use tablepro_core::meta::{ObjectInfo, TableRef};

/// What the user asked the sidebar for. The workspace carries it out.
#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) enum SidebarEvent {
    /// A click, Enter or a double click: the table's tab, or a new one.
    Open(TableRef),
    OpenInNewTab(TableRef),
    EditStructure(TableRef),
    ShowCreateTable(TableRef),
    ImportCsv(TableRef),
    DropTable(TableRef),
    /// A new table in this schema, or the default one.
    NewTable(Option<String>),
    /// This schema's ER diagram, or the default one's.
    ShowDiagram(Option<String>),
    ShowDefinition(ObjectInfo),
}
