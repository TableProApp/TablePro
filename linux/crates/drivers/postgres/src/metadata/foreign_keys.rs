use tablepro_core::ddl::{OutboundForeignKey, ReferentialAction};
use tablepro_core::{DriverError, ForeignKeyInfo};
use tokio_postgres::{Client, Row};

use super::{decode_error, text_rows};
use crate::catalog::{PARENT_HOLDS_CHILD, compares_alike_sql};

/// A key to a partitioned table has a clone on the same table for each
/// partition it reaches, made and dropped with it, so only the key the
/// user declared is listed.
const FOREIGN_KEYS_SQL: &str = "\
SELECT c.conname::text,
       ARRAY(SELECT a.attname::text
               FROM unnest(c.conkey) WITH ORDINALITY AS k(attnum, ord)
               JOIN pg_catalog.pg_attribute a ON a.attrelid = c.conrelid AND a.attnum = k.attnum
              ORDER BY k.ord),
       n.nspname::text,
       t.relname::text,
       ARRAY(SELECT a.attname::text
               FROM unnest(c.confkey) WITH ORDINALITY AS k(attnum, ord)
               JOIN pg_catalog.pg_attribute a ON a.attrelid = c.confrelid AND a.attnum = k.attnum
              ORDER BY k.ord),
       c.confdeltype::text,
       c.confupdtype::text,
       {parent_compares_alike}
FROM pg_catalog.pg_constraint c
JOIN pg_catalog.pg_class t ON t.oid = c.confrelid
JOIN pg_catalog.pg_namespace n ON n.oid = t.relnamespace
WHERE c.conrelid = $1::text::regclass AND c.contype = 'f'
  AND NOT EXISTS (SELECT 1 FROM pg_catalog.pg_constraint p
                   WHERE p.oid = c.conparentid AND p.conrelid = c.conrelid)
ORDER BY c.conname";

fn foreign_keys_sql() -> String {
    FOREIGN_KEYS_SQL.replace("{parent_compares_alike}", &compares_alike_sql(PARENT_HOLDS_CHILD))
}

pub(crate) async fn fetch_foreign_keys(client: &Client, relation: &str) -> Result<Vec<ForeignKeyInfo>, DriverError> {
    Ok(fetch_outbound_foreign_keys(client, relation)
        .await?
        .into_iter()
        .map(|outbound| outbound.key)
        .collect())
}

pub(crate) async fn fetch_outbound_foreign_keys(
    client: &Client,
    relation: &str,
) -> Result<Vec<OutboundForeignKey>, DriverError> {
    text_rows(client, &foreign_keys_sql(), &[relation])
        .await?
        .iter()
        .map(outbound_foreign_key)
        .collect()
}

fn outbound_foreign_key(row: &Row) -> Result<OutboundForeignKey, DriverError> {
    let field = decode_error("pg_constraint");
    let on_delete: String = row.try_get(5).map_err(&field)?;
    let on_update: String = row.try_get(6).map_err(&field)?;
    Ok(OutboundForeignKey {
        key: ForeignKeyInfo {
            name: row.try_get(0).map_err(&field)?,
            columns: row.try_get(1).map_err(&field)?,
            ref_schema: Some(row.try_get(2).map_err(&field)?),
            ref_table: row.try_get(3).map_err(&field)?,
            ref_columns: row.try_get(4).map_err(&field)?,
            on_delete: referential_action(&on_delete),
            on_update: referential_action(&on_update),
        },
        parent_compares_alike: row.try_get(7).map_err(&field)?,
    })
}

/// `pg_constraint.confdeltype` and `confupdtype`.
fn referential_action(code: &str) -> Option<ReferentialAction> {
    Some(match code {
        "a" => ReferentialAction::NoAction,
        "r" => ReferentialAction::Restrict,
        "c" => ReferentialAction::Cascade,
        "n" => ReferentialAction::SetNull,
        "d" => ReferentialAction::SetDefault,
        _ => return None,
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn action_codes_map_to_actions() {
        assert_eq!(referential_action("a"), Some(ReferentialAction::NoAction));
        assert_eq!(referential_action("c"), Some(ReferentialAction::Cascade));
        assert_eq!(referential_action("d"), Some(ReferentialAction::SetDefault));
        assert_eq!(referential_action("?"), None);
    }
}
