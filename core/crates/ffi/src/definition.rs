use tablepro_core::meta::{ObjectDefinition, ObjectInfo, ObjectKind};

use crate::catalog::{ObjectEntry, ObjectKindTag};
use crate::error::CoreError;

// `database`: where `sql` runs when it names none. `opens_in_editor`: false when an editor run would not make it.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct ObjectSource {
    pub sql: String,
    pub database: Option<String>,
    pub opens_in_editor: bool,
}

impl From<ObjectDefinition> for ObjectSource {
    fn from(definition: ObjectDefinition) -> Self {
        Self {
            sql: definition.sql,
            database: definition.database,
            opens_in_editor: definition.refusal.is_none(),
        }
    }
}

// A key's kind and a kind this build does not name carry too little for a driver to find the object by.
impl TryFrom<ObjectEntry> for ObjectInfo {
    type Error = CoreError;

    fn try_from(entry: ObjectEntry) -> Result<Self, Self::Error> {
        let kind = match entry.kind {
            ObjectKindTag::Table => ObjectKind::Table,
            ObjectKindTag::PartitionedTable => ObjectKind::PartitionedTable,
            ObjectKindTag::View => ObjectKind::View,
            ObjectKindTag::MaterializedView => ObjectKind::MaterializedView,
            ObjectKindTag::ForeignTable => ObjectKind::ForeignTable,
            ObjectKindTag::Sequence => ObjectKind::Sequence,
            ObjectKindTag::Function => ObjectKind::Function,
            ObjectKindTag::Procedure => ObjectKind::Procedure,
            ObjectKindTag::Trigger => ObjectKind::Trigger,
            ObjectKindTag::Dictionary => ObjectKind::Dictionary,
            ObjectKindTag::Key | ObjectKindTag::Other => {
                return Err(CoreError::failed(
                    "ffi.no_definition",
                    "a key or an object of an unknown kind has no definition to read",
                ));
            }
        };
        Ok(Self {
            schema: entry.schema,
            name: entry.name,
            kind,
            parent_table: entry.parent_table,
        })
    }
}

#[cfg(test)]
mod tests {
    use tablepro_core::meta::EditorRefusal;

    use super::*;

    fn entry(kind: ObjectKindTag) -> ObjectEntry {
        ObjectEntry {
            schema: Some("public".to_owned()),
            name: "audit".to_owned(),
            kind,
            parent_table: Some("orders".to_owned()),
        }
    }

    #[test]
    fn a_trigger_keeps_its_table_on_the_way_in() {
        let info = ObjectInfo::try_from(entry(ObjectKindTag::Trigger)).unwrap();

        assert_eq!(info, ObjectInfo::trigger(Some("public".to_owned()), "audit", "orders"));
    }

    #[test]
    fn a_key_and_an_unknown_kind_are_refused() {
        for kind in [ObjectKindTag::Key, ObjectKindTag::Other] {
            let refused = ObjectInfo::try_from(entry(kind)).unwrap_err();

            assert_eq!(refused.code(), "ffi.no_definition");
        }
    }

    #[test]
    fn a_refusal_keeps_the_text_out_of_the_editor() {
        let source = ObjectSource::from(ObjectDefinition {
            sql: "CREATE PROCEDURE p AS SELECT 1".to_owned(),
            database: Some("shop".to_owned()),
            refusal: Some(EditorRefusal::SplitsApart),
        });

        assert!(!source.opens_in_editor);
        assert_eq!(source.database.as_deref(), Some("shop"));
    }
}
