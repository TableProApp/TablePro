use tablepro_core::DriverError;
use tablepro_core::meta::{IndexInfo, IndexKey};
use tokio_postgres::Client;

use super::{decode_error, text_rows};

/// One row per key column, the INCLUDE columns past `indnkeyatts` left
/// out. Attribute number 0 marks an expression, which only
/// `pg_get_indexdef` can print.
const INDEXES_SQL: &str = "\
SELECT ic.relname::text,
       i.indisunique,
       i.indisprimary,
       pg_catalog.pg_get_expr(i.indpred, i.indrelid)::text,
       a.attname::text,
       pg_catalog.pg_get_indexdef(i.indexrelid, k.ord::int4, true)::text,
       COALESCE(pg_catalog.pg_index_column_has_property(i.indexrelid, k.ord::int4, 'desc'), false)
FROM pg_catalog.pg_index i
JOIN pg_catalog.pg_class ic ON ic.oid = i.indexrelid
CROSS JOIN LATERAL unnest(i.indkey::int2[]) WITH ORDINALITY AS k(attnum, ord)
LEFT JOIN pg_catalog.pg_attribute a ON a.attrelid = i.indrelid AND a.attnum = k.attnum AND k.attnum > 0
WHERE i.indrelid = $1::text::regclass AND k.ord <= i.indnkeyatts
ORDER BY ic.relname, k.ord";

pub(crate) async fn fetch_indexes(client: &Client, relation: &str) -> Result<Vec<IndexInfo>, DriverError> {
    let field = decode_error("pg_index");
    let mut indexes: Vec<IndexInfo> = Vec::new();
    for row in text_rows(client, INDEXES_SQL, &[relation]).await? {
        let name: String = row.try_get(0).map_err(&field)?;
        let column: Option<String> = row.try_get(4).map_err(&field)?;
        let expression: String = row.try_get(5).map_err(&field)?;
        let descending: bool = row.try_get(6).map_err(&field)?;
        let key = match column {
            Some(name) => IndexKey::Column { name, descending },
            None => IndexKey::Expression {
                sql: expression,
                descending,
            },
        };
        match indexes.last_mut() {
            Some(index) if index.name == name => index.keys.push(key),
            _ => indexes.push(IndexInfo {
                name,
                keys: vec![key],
                unique: row.try_get(1).map_err(&field)?,
                primary: row.try_get(2).map_err(&field)?,
                predicate: row.try_get(3).map_err(&field)?,
            }),
        }
    }
    Ok(indexes)
}
