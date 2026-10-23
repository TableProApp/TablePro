use tablepro_core::meta::TableRef;

use super::editor_label::EditorLabel;
use super::structure_target::StructureTarget;

/// What a tab shows, as far as its title goes.
#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) enum TabIdentity {
    Table(TableRef),
    Structure(StructureTarget),
    Editor(EditorLabel),
    /// The ER diagram of a schema.
    Diagram(Option<String>),
}
