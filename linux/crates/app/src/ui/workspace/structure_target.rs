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

impl StructureTarget {
    /// A tab with no table name yet is a draft, so its title is never
    /// empty.
    pub(crate) fn of(schema: Option<&str>, table: &str) -> Self {
        if table.trim().is_empty() {
            Self::NewDraft {
                schema: schema.map(str::to_owned),
            }
        } else {
            Self::Existing(TableRef::new(schema.map(str::to_owned), table))
        }
    }
}
