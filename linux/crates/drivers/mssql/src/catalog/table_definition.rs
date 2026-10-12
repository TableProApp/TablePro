use tablepro_core::DriverError;
use tablepro_core::ddl::{InboundForeignKey, PrimaryKeyConstraint};
use tablepro_core::meta::TableRef;
use tablepro_core::value::Value;

use super::cells::Cells;

/// The primary key constraint's name and its columns in key order.
pub(crate) const PRIMARY_KEY_SQL: &str = "SELECT kc.name, c.name \
    FROM sys.key_constraints kc \
    JOIN sys.index_columns ic ON ic.object_id = kc.parent_object_id AND ic.index_id = kc.unique_index_id \
    JOIN sys.columns c ON c.object_id = ic.object_id AND c.column_id = ic.column_id \
    WHERE kc.parent_object_id = OBJECT_ID(@P1) AND kc.type = 'PK' AND ic.key_ordinal > 0 \
    ORDER BY ic.key_ordinal";

/// The foreign keys on other tables that point at this one, one row per
/// column pair, in key order.
pub(crate) const INBOUND_FOREIGN_KEYS_SQL: &str = "SELECT fk.name, SCHEMA_NAME(p.schema_id), p.name, pc.name, rc.name \
    FROM sys.foreign_keys fk \
    JOIN sys.objects p ON p.object_id = fk.parent_object_id \
    JOIN sys.foreign_key_columns fkc ON fkc.constraint_object_id = fk.object_id \
    JOIN sys.columns pc ON pc.object_id = fkc.parent_object_id AND pc.column_id = fkc.parent_column_id \
    JOIN sys.columns rc ON rc.object_id = fkc.referenced_object_id AND rc.column_id = fkc.referenced_column_id \
    WHERE fk.referenced_object_id = OBJECT_ID(@P1) \
    ORDER BY SCHEMA_NAME(p.schema_id), p.name, fk.name, fkc.constraint_column_id";

pub(crate) fn primary_key(rows: &[Vec<Value>]) -> Result<Option<PrimaryKeyConstraint>, DriverError> {
    let mut constraint: Option<PrimaryKeyConstraint> = None;
    for row in rows {
        let cells = Cells::new(row, "sys.key_constraints");
        let column = cells.required_text(1)?;
        match &mut constraint {
            Some(constraint) => constraint.columns.push(column),
            None => {
                constraint = Some(PrimaryKeyConstraint {
                    name: cells.text(0),
                    columns: vec![column],
                });
            }
        }
    }
    Ok(constraint)
}

pub(crate) fn inbound_foreign_keys(rows: &[Vec<Value>]) -> Result<Vec<InboundForeignKey>, DriverError> {
    let mut keys: Vec<InboundForeignKey> = Vec::new();
    for row in rows {
        let cells = Cells::new(row, "sys.foreign_keys");
        let name = cells.required_text(0)?;
        let table = TableRef::new(cells.text(1), cells.required_text(2)?);
        let column = cells.required_text(3)?;
        let referenced = cells.required_text(4)?;
        match keys.last_mut() {
            Some(key) if key.name == name && key.table == table => {
                key.columns.push(column);
                key.referenced_columns.push(referenced);
            }
            _ => keys.push(InboundForeignKey {
                name,
                table,
                columns: vec![column],
                referenced_columns: vec![referenced],
            }),
        }
    }
    Ok(keys)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn text(value: &str) -> Value {
        Value::Text(value.to_owned())
    }

    #[test]
    fn a_composite_primary_key_keeps_its_name_and_order() {
        let rows = vec![
            vec![text("PK_lines"), text("order_id")],
            vec![text("PK_lines"), text("line_no")],
        ];

        let key = primary_key(&rows).unwrap().unwrap();

        assert_eq!(key.name.as_deref(), Some("PK_lines"));
        assert_eq!(key.columns, ["order_id", "line_no"]);
        assert_eq!(primary_key(&[]).unwrap(), None);
    }

    #[test]
    fn inbound_keys_group_their_column_pairs() {
        let rows = vec![
            vec![text("FK_a"), text("dbo"), text("lines"), text("order_id"), text("id")],
            vec![text("FK_a"), text("dbo"), text("lines"), text("tenant"), text("tenant")],
            vec![
                text("FK_b"),
                text("sales"),
                text("refunds"),
                text("order_id"),
                text("id"),
            ],
        ];

        let keys = inbound_foreign_keys(&rows).unwrap();

        assert_eq!(keys.len(), 2);
        assert_eq!(keys[0].table, TableRef::new(Some("dbo".to_owned()), "lines"));
        assert_eq!(keys[0].columns, ["order_id", "tenant"]);
        assert_eq!(keys[0].referenced_columns, ["id", "tenant"]);
        assert_eq!(keys[1].name, "FK_b");
    }
}
