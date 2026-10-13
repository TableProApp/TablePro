use tablepro_core::DriverError;
use tablepro_core::ddl::InboundForeignKey;
use tablepro_core::meta::TableRef;

use super::catalog_cells::CatalogCells;

/// Foreign keys on other tables that point at this one, one row per
/// column in key order.
pub(crate) const INBOUND_FOREIGN_KEYS_SQL: &str = "\
SELECT CONSTRAINT_NAME, TABLE_SCHEMA, TABLE_NAME, COLUMN_NAME, REFERENCED_COLUMN_NAME
FROM information_schema.KEY_COLUMN_USAGE
WHERE REFERENCED_TABLE_SCHEMA = COALESCE(?, DATABASE()) AND REFERENCED_TABLE_NAME = ?
ORDER BY TABLE_SCHEMA, TABLE_NAME, CONSTRAINT_NAME, ORDINAL_POSITION";

/// Engine attributes on columns, which MySQL 8.0.21 and later keep apart
/// from COLUMNS and which this build does not model.
pub(crate) const COLUMN_ENGINE_ATTRIBUTES_SQL: &str = "\
SELECT COLUMN_NAME, ENGINE_ATTRIBUTE, SECONDARY_ENGINE_ATTRIBUTE
FROM information_schema.COLUMNS_EXTENSIONS
WHERE TABLE_SCHEMA = COALESCE(?, DATABASE()) AND TABLE_NAME = ?";

/// MariaDB's SRID of each geometry column. COLUMNS and SHOW CREATE TABLE
/// leave it out, and a MODIFY that does not restate it resets it to 0.
/// The F_ names are the ones the server looks a table up by.
pub(crate) const MARIADB_GEOMETRY_SRIDS_SQL: &str = "\
SELECT G_GEOMETRY_COLUMN, SRID
FROM information_schema.GEOMETRY_COLUMNS
WHERE F_TABLE_SCHEMA = COALESCE(?, DATABASE()) AND F_TABLE_NAME = ?";

/// MariaDB's CHECK constraints written on a column, each named after its
/// column. A MODIFY that does not restate one drops it, the `json_valid`
/// check MariaDB puts on every JSON column included.
pub(crate) const MARIADB_COLUMN_CHECKS_SQL: &str = "\
SELECT CONSTRAINT_NAME, CHECK_CLAUSE
FROM information_schema.CHECK_CONSTRAINTS
WHERE CONSTRAINT_SCHEMA = COALESCE(?, DATABASE()) AND TABLE_NAME = ? AND LEVEL = 'Column'";

/// Each geometry column that sets an SRID. MariaDB lists 0 for one that
/// sets none.
pub(crate) fn geometry_srids(rows: &[CatalogCells]) -> Result<Vec<(String, u64)>, DriverError> {
    let mut srids = Vec::new();
    for row in rows {
        let column = row.required_text(0)?;
        if let Some(srid) = row.number(1)?.filter(|srid| *srid != 0) {
            srids.push((column, srid));
        }
    }
    Ok(srids)
}

/// Each column's own CHECK clause, as SQL.
pub(crate) fn column_checks(rows: &[CatalogCells]) -> Result<Vec<(String, String)>, DriverError> {
    rows.iter()
        .map(|row| Ok((row.required_text(0)?, row.required_text(1)?)))
        .collect()
}

/// One key per constraint, its columns in order.
pub(crate) fn inbound_foreign_keys(rows: &[CatalogCells]) -> Result<Vec<InboundForeignKey>, DriverError> {
    let mut keys: Vec<InboundForeignKey> = Vec::new();
    for row in rows {
        let name = row.required_text(0)?;
        let schema = row.required_text(1)?;
        let table = row.required_text(2)?;
        let column = row.required_text(3)?;
        let referenced = row.required_text(4)?;
        let same = keys.last_mut().filter(|key| {
            key.name == name && key.table.name == table && key.table.schema.as_deref() == Some(schema.as_str())
        });
        match same {
            Some(key) => {
                key.columns.push(column);
                key.referenced_columns.push(referenced);
            }
            None => keys.push(InboundForeignKey {
                name,
                table: TableRef::new(Some(schema), table),
                columns: vec![column],
                referenced_columns: vec![referenced],
            }),
        }
    }
    Ok(keys)
}

#[cfg(test)]
mod tests {
    use tablepro_core::value::Value;

    use super::*;

    fn row(values: [&str; 5]) -> CatalogCells {
        CatalogCells::new(
            "KEY_COLUMN_USAGE",
            values.iter().map(|text| Value::Text((*text).to_owned())).collect(),
        )
    }

    #[test]
    fn only_a_geometry_column_that_sets_an_srid_keeps_one() {
        let rows = [
            CatalogCells::new(
                "GEOMETRY_COLUMNS",
                vec![Value::Text("shape".to_owned()), Value::UInt(4326)],
            ),
            CatalogCells::new("GEOMETRY_COLUMNS", vec![Value::Text("area".to_owned()), Value::Int(0)]),
        ];

        assert_eq!(geometry_srids(&rows).expect("SRIDs"), [("shape".to_owned(), 4326)]);
    }

    #[test]
    fn a_composite_key_collects_its_columns_in_order() {
        let rows = [
            row(["fk_line", "shop", "lines", "order_id", "id"]),
            row(["fk_line", "shop", "lines", "order_rev", "rev"]),
            row(["fk_note", "shop", "notes", "order_id", "id"]),
        ];

        let keys = inbound_foreign_keys(&rows).expect("keys");

        assert_eq!(keys.len(), 2);
        assert_eq!(keys[0].columns, ["order_id", "order_rev"]);
        assert_eq!(keys[0].referenced_columns, ["id", "rev"]);
        assert_eq!(keys[1].table, TableRef::new(Some("shop".to_owned()), "notes"));
    }
}
