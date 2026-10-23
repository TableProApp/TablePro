use std::collections::HashMap;

use tablepro_core::DriverError;

use super::catalog_cells::CatalogCells;

/// What decides how a column compares, for each column of one table.
pub(crate) const COLUMN_COMPARISONS_SQL: &str = "\
SELECT COLUMN_NAME, DATA_TYPE, COLUMN_TYPE, COLLATION_NAME
FROM information_schema.COLUMNS
WHERE TABLE_SCHEMA = COALESCE(?, DATABASE()) AND TABLE_NAME = ?";

/// A column's type, sign and collation. A key may pair CHAR with VARCHAR
/// or BINARY with VARBINARY, which compare padded where `=` on one side
/// does not, so the type is compared by name.
#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct ColumnComparison {
    data_type: String,
    unsigned: bool,
    collation: Option<String>,
}

/// Keyed by the column's name in lower case, since MySQL matches column
/// names without regard to case.
pub(crate) type TableComparisons = HashMap<String, ColumnComparison>;

pub(crate) fn column_comparisons(rows: &[CatalogCells]) -> Result<TableComparisons, DriverError> {
    rows.iter()
        .map(|row| {
            let column_type = row.required_text(2)?.to_ascii_lowercase();
            Ok((
                row.required_text(0)?.to_lowercase(),
                ColumnComparison {
                    data_type: row.required_text(1)?.to_ascii_lowercase(),
                    unsigned: column_type.contains("unsigned"),
                    collation: row.text(3)?,
                },
            ))
        })
        .collect()
}

/// Whether each column of `from` compares like the column of `to` it
/// pairs with. A column the catalogue does not list, as in a table
/// dropped while foreign key checks were off, says nothing either way.
pub(crate) fn compares_alike(
    from: &TableComparisons,
    from_columns: &[String],
    to: &TableComparisons,
    to_columns: &[String],
) -> bool {
    from_columns.iter().zip(to_columns).all(|(from_column, to_column)| {
        match (from.get(&from_column.to_lowercase()), to.get(&to_column.to_lowercase())) {
            (Some(from), Some(to)) => from == to,
            _ => true,
        }
    })
}

#[cfg(test)]
mod tests {
    use tablepro_core::value::Value;

    use super::*;

    fn table(rows: &[[Option<&str>; 4]]) -> TableComparisons {
        let rows: Vec<CatalogCells> = rows
            .iter()
            .map(|row| {
                CatalogCells::new(
                    "COLUMNS",
                    row.iter()
                        .map(|cell| cell.map_or(Value::Null, |text| Value::Text(text.to_owned())))
                        .collect(),
                )
            })
            .collect();
        column_comparisons(&rows).expect("rows that read")
    }

    fn names(names: &[&str]) -> Vec<String> {
        names.iter().map(|name| (*name).to_owned()).collect()
    }

    #[test]
    fn columns_compare_alike_by_type_sign_and_collation() {
        let orders = table(&[
            [Some("Customer_Id"), Some("int"), Some("int"), None],
            [Some("code"), Some("char"), Some("char(4)"), Some("utf8mb4_0900_ai_ci")],
            [Some("owner"), Some("int"), Some("int unsigned"), None],
        ]);
        let customers = table(&[
            [Some("id"), Some("int"), Some("int"), None],
            [
                Some("code"),
                Some("varchar"),
                Some("varchar(4)"),
                Some("utf8mb4_0900_ai_ci"),
            ],
        ]);

        assert!(compares_alike(
            &orders,
            &names(&["customer_id"]),
            &customers,
            &names(&["ID"])
        ));
        assert!(!compares_alike(
            &orders,
            &names(&["code"]),
            &customers,
            &names(&["code"])
        ));
        assert!(!compares_alike(
            &orders,
            &names(&["owner"]),
            &customers,
            &names(&["id"])
        ));
        assert!(compares_alike(
            &orders,
            &names(&["customer_id"]),
            &TableComparisons::new(),
            &names(&["id"])
        ));
    }
}
