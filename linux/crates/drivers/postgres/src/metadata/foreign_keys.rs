use tablepro_core::ddl::ReferentialAction;
use tablepro_core::{DriverError, ForeignKeyInfo};
use tokio_postgres::Client;

use super::{decode_error, text_rows};

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
       c.confupdtype::text
FROM pg_catalog.pg_constraint c
JOIN pg_catalog.pg_class t ON t.oid = c.confrelid
JOIN pg_catalog.pg_namespace n ON n.oid = t.relnamespace
WHERE c.conrelid = $1::text::regclass AND c.contype = 'f'
ORDER BY c.conname";

pub(crate) async fn fetch_foreign_keys(client: &Client, relation: &str) -> Result<Vec<ForeignKeyInfo>, DriverError> {
    let field = decode_error("pg_constraint");
    text_rows(client, FOREIGN_KEYS_SQL, &[relation])
        .await?
        .iter()
        .map(|row| {
            let on_delete: String = row.try_get(5).map_err(&field)?;
            let on_update: String = row.try_get(6).map_err(&field)?;
            Ok(ForeignKeyInfo {
                name: row.try_get(0).map_err(&field)?,
                columns: row.try_get(1).map_err(&field)?,
                ref_schema: Some(row.try_get(2).map_err(&field)?),
                ref_table: row.try_get(3).map_err(&field)?,
                ref_columns: row.try_get(4).map_err(&field)?,
                on_delete: referential_action(&on_delete),
                on_update: referential_action(&on_update),
            })
        })
        .collect()
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
