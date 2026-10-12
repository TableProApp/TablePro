use tablepro_core::DriverError;
use tablepro_core::meta::{EngineRowId, RowIdentity};
use tokio_postgres::Client;

use super::{decode_error, text_rows};

/// The relation's kind, its primary key, and the first unique index that
/// can stand in for one: no predicate, no expressions, and every key
/// column NOT NULL, so it names every row exactly once.
const IDENTITY_SQL: &str = "\
SELECT c.relkind::text,
       ARRAY(SELECT a.attname::text
               FROM pg_catalog.pg_constraint p
               CROSS JOIN LATERAL unnest(p.conkey) WITH ORDINALITY AS k(attnum, ord)
               JOIN pg_catalog.pg_attribute a ON a.attrelid = p.conrelid AND a.attnum = k.attnum
              WHERE p.conrelid = c.oid AND p.contype = 'p'
              ORDER BY k.ord),
       ARRAY(SELECT a.attname::text
               FROM (SELECT i.indrelid, i.indkey, i.indnkeyatts
                       FROM pg_catalog.pg_index i
                       JOIN pg_catalog.pg_class ic ON ic.oid = i.indexrelid
                      WHERE i.indrelid = c.oid
                        AND i.indisunique
                        AND i.indisvalid
                        AND i.indpred IS NULL
                        AND i.indexprs IS NULL
                        AND NOT EXISTS (
                            SELECT 1
                              FROM unnest(i.indkey::int2[]) WITH ORDINALITY AS u(attnum, ord)
                              JOIN pg_catalog.pg_attribute ua
                                ON ua.attrelid = i.indrelid AND ua.attnum = u.attnum
                             WHERE u.ord <= i.indnkeyatts AND NOT ua.attnotnull)
                      ORDER BY ic.relname
                      LIMIT 1) best
               CROSS JOIN LATERAL unnest(best.indkey::int2[]) WITH ORDINALITY AS k(attnum, ord)
               JOIN pg_catalog.pg_attribute a ON a.attrelid = best.indrelid AND a.attnum = k.attnum
              WHERE k.ord <= best.indnkeyatts
              ORDER BY k.ord)
FROM pg_catalog.pg_class c
WHERE c.oid = $1::text::regclass";

pub(crate) async fn row_identity(client: &Client, relation: &str) -> Result<RowIdentity, DriverError> {
    let field = decode_error("pg_class");
    let rows = text_rows(client, IDENTITY_SQL, &[relation]).await?;
    let Some(row) = rows.first() else {
        return Ok(RowIdentity::Unordered);
    };
    let relkind: String = row.try_get(0).map_err(&field)?;
    let primary_key: Vec<String> = row.try_get(1).map_err(&field)?;
    let unique_key: Vec<String> = row.try_get(2).map_err(&field)?;
    Ok(identity(&relkind, primary_key, unique_key))
}

/// The best way to name a row again: a key, else the physical address
/// with its tuple version, else nothing.
fn identity(relkind: &str, primary_key: Vec<String>, unique_key: Vec<String>) -> RowIdentity {
    if !primary_key.is_empty() {
        return RowIdentity::UniqueKey { columns: primary_key };
    }
    if !unique_key.is_empty() {
        return RowIdentity::UniqueKey { columns: unique_key };
    }
    match relkind {
        "r" | "m" => RowIdentity::EngineRowId(EngineRowId::PostgresCtid),
        // A ctid is unique only within one partition.
        "p" => RowIdentity::EngineRowId(EngineRowId::PostgresTableoidCtid),
        _ => RowIdentity::Unordered,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn identity_ladder_prefers_a_key_then_the_row_address() {
        let names = |names: &[&str]| names.iter().map(|name| (*name).to_owned()).collect::<Vec<_>>();

        assert_eq!(
            identity("r", names(&["id"]), names(&["email"])),
            RowIdentity::UniqueKey {
                columns: names(&["id"])
            }
        );
        assert_eq!(
            identity("r", Vec::new(), names(&["email"])),
            RowIdentity::UniqueKey {
                columns: names(&["email"])
            }
        );
        assert_eq!(
            identity("r", Vec::new(), Vec::new()),
            RowIdentity::EngineRowId(EngineRowId::PostgresCtid)
        );
        assert_eq!(
            identity("p", Vec::new(), Vec::new()),
            RowIdentity::EngineRowId(EngineRowId::PostgresTableoidCtid)
        );
        assert_eq!(identity("v", Vec::new(), Vec::new()), RowIdentity::Unordered);
    }
}
