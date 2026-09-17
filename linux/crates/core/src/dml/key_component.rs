use crate::column::ColumnInfo;
use crate::meta::{EngineRowIdPart, RowIdentity};

use super::BuildSqlError;

/// One part of the key that names a row.
///
/// Either a real column the user can see, or a piece of the engine's
/// own row address that the page projected as a hidden column.
#[derive(Debug, Clone, Copy, PartialEq)]
pub enum KeyComponent<'a> {
    Column(&'a ColumnInfo),
    EngineRowId(EngineRowIdPart),
}

/// The key's parts, in the one order everything else follows.
///
/// The page layout projects them in this order, the change set stores
/// its key values in it, and the UPDATE predicate binds them in it. One
/// function so those three cannot drift apart.
pub fn key_components<'a>(
    identity: &RowIdentity,
    columns: &'a [ColumnInfo],
) -> Result<Vec<KeyComponent<'a>>, BuildSqlError> {
    match identity {
        RowIdentity::UniqueKey { columns: names } => by_name(names, columns),
        RowIdentity::SortingKey { expressions } => by_name(expressions, columns),
        RowIdentity::EngineRowId(id) => Ok(id.parts().iter().copied().map(KeyComponent::EngineRowId).collect()),
        RowIdentity::Unordered => Err(BuildSqlError::ReadOnlyRows),
    }
}

fn by_name<'a>(names: &[String], columns: &'a [ColumnInfo]) -> Result<Vec<KeyComponent<'a>>, BuildSqlError> {
    names
        .iter()
        .map(|name| {
            columns
                .iter()
                .find(|column| &column.name == name)
                .map(KeyComponent::Column)
                .ok_or_else(|| BuildSqlError::UnknownKeyColumn { name: name.clone() })
        })
        .collect()
}

#[cfg(test)]
mod tests {
    use crate::column::{CatalogType, ColumnDefault, ColumnKind, ColumnType, IntegerKind, ReadForm, SqlTypeExpr};
    use crate::meta::EngineRowId;

    use super::*;

    fn column(name: &str) -> ColumnInfo {
        ColumnInfo {
            name: name.to_owned(),
            column_type: ColumnType::new(
                SqlTypeExpr::from_catalog_text("integer"),
                ColumnKind::Integer(IntegerKind::I32),
                CatalogType::Oid(23),
                false,
                ReadForm::Native,
            ),
            nullable: false,
            primary_key: true,
            is_auto_increment: false,
            is_generated: false,
            default: ColumnDefault::None,
            comment: None,
        }
    }

    #[test]
    fn a_unique_key_maps_to_its_columns_in_key_order() {
        let columns = [column("tenant"), column("id"), column("other")];
        let identity = RowIdentity::UniqueKey {
            columns: vec!["id".to_owned(), "tenant".to_owned()],
        };

        let parts = key_components(&identity, &columns).expect("the key");

        assert_eq!(
            parts,
            vec![KeyComponent::Column(&columns[1]), KeyComponent::Column(&columns[0])]
        );
    }

    #[test]
    fn a_key_naming_a_column_the_table_lost_is_an_error() {
        let identity = RowIdentity::UniqueKey {
            columns: vec!["gone".to_owned()],
        };

        let error = key_components(&identity, &[column("id")]).expect_err("a missing column");

        assert_eq!(
            error,
            BuildSqlError::UnknownKeyColumn {
                name: "gone".to_owned()
            }
        );
    }

    #[test]
    fn an_engine_row_id_maps_to_its_parts() {
        let identity = RowIdentity::EngineRowId(EngineRowId::PostgresTableoidCtid);

        let parts = key_components(&identity, &[]).expect("the key");

        assert_eq!(
            parts,
            vec![
                KeyComponent::EngineRowId(EngineRowIdPart::PostgresTableOid),
                KeyComponent::EngineRowId(EngineRowIdPart::PostgresCtid),
            ]
        );
    }

    #[test]
    fn key_components_unordered_is_read_only() {
        let error = key_components(&RowIdentity::Unordered, &[column("id")]).expect_err("no identity");

        assert_eq!(error, BuildSqlError::ReadOnlyRows);
    }
}
