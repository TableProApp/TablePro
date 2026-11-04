use crate::column::ColumnInfo;
use crate::ddl::ColumnDefinition;

/// A table column as an import writes it.
#[derive(Debug, Clone, PartialEq)]
pub struct ImportColumn {
    pub info: ColumnInfo,
    /// The server fills the column whatever the file holds: a generated
    /// column, or an identity that refuses a value of its own. The
    /// import never maps a field to it, so no value is dropped unseen.
    pub server_filled: bool,
}

impl ImportColumn {
    pub fn from_definition(definition: &ColumnDefinition) -> Self {
        Self {
            server_filled: definition.info.is_generated || !definition.attributes.identity.accepts_explicit_value(),
            info: definition.info.clone(),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::column::{ColumnDefault, ColumnType};
    use crate::ddl::{ColumnAttributes, IdentityStyle};

    fn definition(identity: IdentityStyle, generated: bool) -> ColumnDefinition {
        ColumnDefinition::new(
            ColumnInfo {
                name: "id".to_owned(),
                column_type: ColumnType::unknown(),
                nullable: false,
                primary_key: true,
                is_auto_increment: identity != IdentityStyle::None,
                is_generated: generated,
                partition_scoped: false,
                default: ColumnDefault::None,
                comment: None,
            },
            ColumnAttributes {
                identity,
                ..ColumnAttributes::default()
            },
        )
    }

    #[test]
    fn an_identity_that_takes_a_value_is_filled_from_the_file() {
        for identity in [
            IdentityStyle::GeneratedByDefault,
            IdentityStyle::SequenceDefault,
            IdentityStyle::AutoIncrementKeyword,
            IdentityStyle::SqliteRowidAlias,
        ] {
            assert!(
                !ImportColumn::from_definition(&definition(identity, false)).server_filled,
                "{identity:?}"
            );
        }
    }

    #[test]
    fn a_generated_column_or_a_refusing_identity_is_left_to_the_server() {
        assert!(ImportColumn::from_definition(&definition(IdentityStyle::GeneratedAlways, false)).server_filled);
        assert!(ImportColumn::from_definition(&definition(IdentityStyle::MssqlIdentity, false)).server_filled);
        assert!(ImportColumn::from_definition(&definition(IdentityStyle::None, true)).server_filled);
    }
}
