use std::collections::HashMap;

use tablepro_core::DriverError;

use super::catalog_cells::CatalogCells;

/// What decides how a column compares, for each column of one table.
pub(crate) const COLUMN_COMPARISONS_SQL: &str = "\
SELECT COLUMN_NAME, DATA_TYPE, COLUMN_TYPE, COLLATION_NAME
FROM information_schema.COLUMNS
WHERE TABLE_SCHEMA = COALESCE(?, DATABASE()) AND TABLE_NAME = ?";

/// A column's type and collation. A key may pair CHAR with VARCHAR or
/// BINARY with VARBINARY, which compare padded where `=` on one side
/// does not, so the type is compared by name. InnoDB compares a key by
/// the stored form, so an ENUM by member number and a DECIMAL by its
/// encoded digits: their members, precision and scale count too.
#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct ColumnComparison {
    data_type: String,
    parameters: String,
    collation: Option<String>,
}

/// Keyed by the column's name in lower case, since MySQL matches column
/// names without regard to case.
pub(crate) type TableComparisons = HashMap<String, ColumnComparison>;

pub(crate) fn column_comparisons(rows: &[CatalogCells]) -> Result<TableComparisons, DriverError> {
    rows.iter()
        .map(|row| {
            let data_type = row.required_text(1)?.to_ascii_lowercase();
            let parameters = parameters(&data_type, &row.required_text(2)?);
            Ok((
                row.required_text(0)?.to_lowercase(),
                ColumnComparison {
                    data_type,
                    parameters,
                    collation: row.text(3)?,
                },
            ))
        })
        .collect()
}

/// What of COLUMN_TYPE changes how a key compares: an integer's sign,
/// not its display width; no string's length; every other type's whole
/// spelling, members in their own case.
fn parameters(data_type: &str, column_type: &str) -> String {
    match data_type {
        "tinyint" | "smallint" | "mediumint" | "int" | "bigint" => {
            match column_type.to_ascii_lowercase().contains("unsigned") {
                true => "unsigned".to_owned(),
                false => String::new(),
            }
        }
        "char" | "varchar" | "binary" | "varbinary" => String::new(),
        _ => column_type.to_owned(),
    }
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
    fn enum_members_and_decimal_digits_count_and_widths_and_lengths_do_not() {
        let child = table(&[
            [Some("mood"), Some("enum"), Some("enum('b','a')"), Some("utf8mb4_bin")],
            [Some("price"), Some("decimal"), Some("decimal(10,2)"), None],
            [Some("owner"), Some("int"), Some("int(11)"), None],
            [Some("code"), Some("varchar"), Some("varchar(8)"), Some("utf8mb4_bin")],
            [Some("label"), Some("enum"), Some("enum('a','B')"), Some("utf8mb4_bin")],
        ]);
        let parent = table(&[
            [Some("mood"), Some("enum"), Some("enum('a','b')"), Some("utf8mb4_bin")],
            [Some("price"), Some("decimal"), Some("decimal(12,2)"), None],
            [Some("owner"), Some("int"), Some("int"), None],
            [Some("code"), Some("varchar"), Some("varchar(4)"), Some("utf8mb4_bin")],
            [Some("label"), Some("enum"), Some("enum('a','b')"), Some("utf8mb4_bin")],
        ]);
        let alike = |column: &str| compares_alike(&child, &names(&[column]), &parent, &names(&[column]));

        assert!(!alike("mood"), "members in another order");
        assert!(!alike("price"), "another precision");
        assert!(alike("owner"), "a display width");
        assert!(alike("code"), "a length");
        assert!(!alike("label"), "a member in another case");
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
