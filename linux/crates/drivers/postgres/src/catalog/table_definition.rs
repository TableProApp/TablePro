use tablepro_core::DriverError;
use tablepro_core::ddl::InboundForeignKey;
use tablepro_core::meta::TableRef;
use tokio_postgres::Row;

/// The primary key constraint's name and its columns in key order.
pub(crate) const PRIMARY_KEY_NAME_SQL: &str = "\
SELECT c.conname::text,
       ARRAY(SELECT a.attname::text
               FROM unnest(c.conkey) WITH ORDINALITY AS k(attnum, ord)
               JOIN pg_catalog.pg_attribute a ON a.attrelid = c.conrelid AND a.attnum = k.attnum
              ORDER BY k.ord)
FROM pg_catalog.pg_constraint c
WHERE c.conrelid = $1::text::regclass AND c.contype = 'p'";

/// Foreign keys on other tables that point at this one.
pub(crate) const INBOUND_FOREIGN_KEYS_SQL: &str = "\
SELECT c.conname::text,
       n.nspname::text,
       t.relname::text,
       ARRAY(SELECT a.attname::text
               FROM unnest(c.conkey) WITH ORDINALITY AS k(attnum, ord)
               JOIN pg_catalog.pg_attribute a ON a.attrelid = c.conrelid AND a.attnum = k.attnum
              ORDER BY k.ord),
       ARRAY(SELECT a.attname::text
               FROM unnest(c.confkey) WITH ORDINALITY AS k(attnum, ord)
               JOIN pg_catalog.pg_attribute a ON a.attrelid = c.confrelid AND a.attnum = k.attnum
              ORDER BY k.ord)
FROM pg_catalog.pg_constraint c
JOIN pg_catalog.pg_class t ON t.oid = c.conrelid
JOIN pg_catalog.pg_namespace n ON n.oid = t.relnamespace
WHERE c.confrelid = $1::text::regclass AND c.contype = 'f'
ORDER BY n.nspname, t.relname, c.conname";

pub(crate) fn inbound_foreign_key(row: &Row) -> Result<InboundForeignKey, DriverError> {
    let field = |error: tokio_postgres::Error| DriverError::Decode {
        column: "pg_constraint".to_owned(),
        detail: error.to_string(),
    };
    let schema: String = row.try_get(1).map_err(field)?;
    let table: String = row.try_get(2).map_err(field)?;
    Ok(InboundForeignKey {
        name: row.try_get(0).map_err(field)?,
        table: TableRef::new(Some(schema), table),
        columns: row.try_get(3).map_err(field)?,
        referenced_columns: row.try_get(4).map_err(field)?,
    })
}
