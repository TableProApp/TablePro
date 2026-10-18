use super::{ColumnDefinition, InboundForeignKey, PrimaryKeyConstraint, TableSource};
use crate::foreign_key_info::ForeignKeyInfo;
use crate::meta::{IndexInfo, TableRef};

/// Everything a structure change needs to know about a table, read in
/// one call.
///
/// The structure tab plans DDL against this rather than against the
/// separate column, index and key lists, because a plan that restates
/// a column, rebuilds a table or renames a key needs all of them from
/// the same moment.
#[derive(Debug, Clone, PartialEq)]
pub struct TableDefinition {
    pub table: TableRef,
    pub columns: Vec<ColumnDefinition>,
    pub primary_key: Option<PrimaryKeyConstraint>,
    pub indexes: Vec<IndexInfo>,
    pub foreign_keys: Vec<ForeignKeyInfo>,
    pub inbound_foreign_keys: Vec<InboundForeignKey>,
    /// `None` where the engine cannot produce its own DDL for the table.
    pub source: Option<TableSource>,
}

impl TableDefinition {
    pub fn column(&self, name: &str) -> Option<&ColumnDefinition> {
        self.columns.iter().find(|column| column.name() == name)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::column::{CatalogType, ColumnDefault, ColumnInfo, ColumnKind, ColumnType, ReadForm, SqlTypeExpr};
    use crate::ddl::{ColumnAttributes, IdentityStyle};

    fn column(name: &str) -> ColumnDefinition {
        ColumnDefinition::new(
            ColumnInfo {
                name: name.to_owned(),
                column_type: ColumnType {
                    name: "text".to_owned(),
                    kind: ColumnKind::Text {
                        length: crate::column::TextLength::Unbounded,
                    },
                    catalog: Some(CatalogType {
                        declaration: SqlTypeExpr::from_catalog_text("text"),
                        cast_target: SqlTypeExpr::from_catalog_text("text"),
                    }),
                    dynamic_storage: false,
                    read_form: ReadForm::Native,
                },
                nullable: true,
                primary_key: false,
                is_auto_increment: false,
                is_generated: false,
                default: ColumnDefault::None,
                comment: None,
            },
            ColumnAttributes::default(),
        )
    }

    #[test]
    fn a_column_is_found_by_its_exact_name() {
        let definition = TableDefinition {
            table: TableRef::unqualified("users"),
            columns: vec![column("email"), column("Email")],
            primary_key: None,
            indexes: Vec::new(),
            foreign_keys: Vec::new(),
            inbound_foreign_keys: Vec::new(),
            source: None,
        };

        assert_eq!(definition.column("Email").map(ColumnDefinition::name), Some("Email"));
        assert!(definition.column("missing").is_none());
    }

    #[test]
    fn default_attributes_describe_a_plain_column() {
        let attributes = ColumnAttributes::default();

        assert_eq!(attributes.identity, IdentityStyle::None);
        assert!(attributes.generated.is_none());
        assert!(attributes.unmodeled.is_empty());
        assert!(!attributes.key_roles.sorting_key && !attributes.key_roles.partition_key);
    }
}
