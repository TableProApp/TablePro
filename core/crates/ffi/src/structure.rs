use tablepro_core::ForeignKeyInfo;
use tablepro_core::column::ColumnDefault;
use tablepro_core::ddl::{ColumnDefinition, ReferentialAction, TableDefinition, default_text};
use tablepro_core::dialect::SqlDialect;
use tablepro_core::meta::{IndexInfo, IndexKey};

use crate::catalog::ObjectKindTag;

// `ddl` is the engine's CREATE script for a table; None for a view, or where the engine writes none.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct TableStructure {
    pub columns: Vec<StructureColumn>,
    pub indexes: Vec<StructureIndex>,
    pub foreign_keys: Vec<StructureForeignKey>,
    pub ddl: Option<String>,
}

// `default_value` is SQL the user could type back in; None when the column has no default.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct StructureColumn {
    pub name: String,
    pub type_name: String,
    pub nullable: bool,
    pub default_value: Option<String>,
    pub primary_key: bool,
    pub auto_increment: bool,
    pub generated: bool,
    pub comment: Option<String>,
}

// Each key is a column name or an expression, with " DESC" after a descending one.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct StructureIndex {
    pub name: String,
    pub keys: Vec<String>,
    pub unique: bool,
    pub primary: bool,
    pub predicate: Option<String>,
}

// An action is None where the server spelled one this build does not know.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct StructureForeignKey {
    pub name: String,
    pub columns: Vec<String>,
    pub ref_schema: Option<String>,
    pub ref_table: String,
    pub ref_columns: Vec<String>,
    pub on_delete: Option<String>,
    pub on_update: Option<String>,
}

pub(crate) fn table_structure(
    definition: &TableDefinition,
    dialect: &dyn SqlDialect,
    kind: ObjectKindTag,
) -> TableStructure {
    TableStructure {
        columns: definition
            .columns
            .iter()
            .map(|column| structure_column(column, dialect))
            .collect(),
        indexes: definition.indexes.iter().map(StructureIndex::from).collect(),
        foreign_keys: definition.foreign_keys.iter().map(StructureForeignKey::from).collect(),
        ddl: match kind {
            ObjectKindTag::Table | ObjectKindTag::PartitionedTable => create_script(definition, dialect),
            // Some engines would build a CREATE TABLE from a view's columns, which is not how the view was made.
            _ => None,
        },
    }
}

fn structure_column(column: &ColumnDefinition, dialect: &dyn SqlDialect) -> StructureColumn {
    let info = &column.info;
    StructureColumn {
        name: info.name.clone(),
        type_name: info.column_type.name.clone(),
        nullable: info.nullable,
        default_value: match &info.default {
            ColumnDefault::None => None,
            default => Some(default_text(dialect, default, &info.column_type)),
        },
        primary_key: info.primary_key,
        auto_increment: info.is_auto_increment,
        generated: info.is_generated || column.attributes.generated.is_some(),
        comment: info.comment.clone(),
    }
}

fn create_script(definition: &TableDefinition, dialect: &dyn SqlDialect) -> Option<String> {
    if definition.columns.is_empty() {
        return None;
    }
    let script = match dialect.ddl()?.create_table_script(definition) {
        Ok(script) => script,
        Err(error) => {
            tracing::warn!(%error, "the table's CREATE script could not be built");
            return None;
        }
    };
    (!script.is_empty()).then(|| script.preview())
}

impl From<&IndexInfo> for StructureIndex {
    fn from(index: &IndexInfo) -> Self {
        Self {
            name: index.name.clone(),
            keys: index.keys.iter().map(key_text).collect(),
            unique: index.unique,
            primary: index.primary,
            predicate: index.predicate.clone(),
        }
    }
}

fn key_text(key: &IndexKey) -> String {
    let text = match key {
        IndexKey::Column { name, .. } => name,
        IndexKey::Expression { sql, .. } => sql,
    };
    match key.descending() {
        true => format!("{text} DESC"),
        false => text.clone(),
    }
}

impl From<&ForeignKeyInfo> for StructureForeignKey {
    fn from(key: &ForeignKeyInfo) -> Self {
        Self {
            name: key.name.clone(),
            columns: key.columns.clone(),
            ref_schema: key.ref_schema.clone(),
            ref_table: key.ref_table.clone(),
            ref_columns: key.ref_columns.clone(),
            on_delete: key.on_delete.map(action_text),
            on_update: key.on_update.map(action_text),
        }
    }
}

fn action_text(action: ReferentialAction) -> String {
    action.as_sql().to_owned()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_descending_key_says_so_after_its_column_or_expression() {
        let index = IndexInfo {
            name: "recent".to_owned(),
            keys: vec![
                IndexKey::Column {
                    name: "created_at".to_owned(),
                    descending: true,
                },
                IndexKey::Expression {
                    sql: "lower(email)".to_owned(),
                    descending: false,
                },
            ],
            unique: true,
            primary: false,
            predicate: Some("deleted_at IS NULL".to_owned()),
            definition: None,
        };

        let shown = StructureIndex::from(&index);

        assert_eq!(shown.keys, ["created_at DESC", "lower(email)"]);
        assert!(shown.unique);
        assert_eq!(shown.predicate.as_deref(), Some("deleted_at IS NULL"));
    }

    #[test]
    fn a_foreign_key_names_its_actions_as_sql_and_leaves_an_unknown_one_out() {
        let key = ForeignKeyInfo {
            name: "orders_customer".to_owned(),
            columns: vec!["customer_id".to_owned()],
            ref_schema: Some("public".to_owned()),
            ref_table: "customers".to_owned(),
            ref_columns: vec!["id".to_owned()],
            on_delete: Some(ReferentialAction::SetNull),
            on_update: None,
        };

        let shown = StructureForeignKey::from(&key);

        assert_eq!(shown.on_delete.as_deref(), Some("SET NULL"));
        assert_eq!(shown.on_update, None);
        assert_eq!(shown.ref_columns, ["id"]);
    }
}
