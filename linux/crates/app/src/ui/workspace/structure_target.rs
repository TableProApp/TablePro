use tablepro_core::meta::TableRef;

/// What a structure tab edits: a table that exists, or the draft of one
/// that does not yet.
#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) enum StructureTarget {
    Existing(TableRef),
    /// The schema the table will be created in.
    NewDraft {
        schema: Option<String>,
    },
}
