use std::collections::HashMap;

use tablepro_core::DriverError;
use tablepro_core::meta::{IndexInfo, IndexKey};
use tokio_postgres::Client;

use super::{decode_error, text_rows};

/// One row per key column, the INCLUDE columns past `indnkeyatts` left
/// out. Attribute number 0 marks an expression, which only
/// `pg_get_indexdef` can print.
pub(super) const INDEXES_SQL: &str = "\
SELECT ic.relname::text,
       i.indisunique,
       i.indisprimary,
       pg_catalog.pg_get_expr(i.indpred, i.indrelid)::text,
       a.attname::text,
       pg_catalog.pg_get_indexdef(i.indexrelid, k.ord::int4, true)::text,
       COALESCE(pg_catalog.pg_index_column_has_property(i.indexrelid, k.ord::int4, 'desc'), false)
FROM pg_catalog.pg_index i
JOIN pg_catalog.pg_class ic ON ic.oid = i.indexrelid
CROSS JOIN LATERAL pg_catalog.unnest(i.indkey::int2[]) WITH ORDINALITY AS k(attnum, ord)
LEFT JOIN pg_catalog.pg_attribute a ON a.attrelid = i.indrelid AND a.attnum = k.attnum AND k.attnum > 0
WHERE i.indrelid = $1::text::regclass::oid AND k.ord <= i.indnkeyatts
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
                definition: None,
            }),
        }
    }
    Ok(indexes)
}

// No statement for an index a constraint of its own table owns (a foreign key's conindid names the
// referenced table's index, hence the conrelid match), nor for a partition's index attached to its
// parent's, which only the parent's statement makes.
pub(super) const INDEX_STATEMENTS_SQL: &str = "\
SELECT ic.relname::text,
       pg_catalog.pg_get_indexdef(i.indexrelid)::text,
       ic.relkind = 'I',
       i.indisunique,
       pg_catalog.quote_ident(ic.relname)::text,
       pg_catalog.quote_ident(ts.spcname)::text,
       pg_catalog.pg_get_expr(i.indpred, i.indrelid)::text
FROM pg_catalog.pg_index i
JOIN pg_catalog.pg_class ic ON ic.oid = i.indexrelid
LEFT JOIN pg_catalog.pg_tablespace ts ON ts.oid = ic.reltablespace
WHERE i.indrelid = $1::text::regclass::oid
  AND NOT EXISTS (
      SELECT 1 FROM pg_catalog.pg_constraint c
      WHERE c.conindid = i.indexrelid AND c.conrelid = i.indrelid AND c.contype IN ('p', 'u', 'x'))
  AND NOT EXISTS (SELECT 1 FROM pg_catalog.pg_inherits h WHERE h.inhrelid = i.indexrelid)";

pub(super) async fn fetch_index_statements(
    client: &Client,
    relation: &str,
) -> Result<HashMap<String, String>, DriverError> {
    let field = decode_error("pg_index");
    text_rows(client, INDEX_STATEMENTS_SQL, &[relation])
        .await?
        .iter()
        .map(|row| {
            let mut statement: String = row.try_get(1).map_err(&field)?;
            if row.try_get(2).map_err(&field)? {
                let quoted_name: String = row.try_get(4).map_err(&field)?;
                statement = without_only(statement, row.try_get(3).map_err(&field)?, &quoted_name);
            }
            if let Some(tablespace) = row.try_get::<_, Option<String>>(5).map_err(&field)? {
                let predicate: Option<String> = row.try_get(6).map_err(&field)?;
                statement = in_tablespace(statement, &tablespace, predicate.as_deref());
            }
            Ok((row.try_get(0).map_err(&field)?, statement))
        })
        .collect()
}

// pg_get_indexdef prints ON ONLY for a partitioned table's index and has no form without it;
// run as is, it builds the parent's index alone, invalid and on no partition.
fn without_only(statement: String, unique: bool, quoted_name: &str) -> String {
    let head = format!("CREATE {}INDEX {quoted_name} ON ", if unique { "UNIQUE " } else { "" });
    match statement
        .strip_prefix(&head)
        .and_then(|rest| rest.strip_prefix("ONLY "))
    {
        Some(rest) => format!("{head}{rest}"),
        None => statement,
    }
}

// pg_get_indexdef leaves the tablespace out. It goes before the predicate, which ends the text.
fn in_tablespace(statement: String, tablespace: &str, predicate: Option<&str>) -> String {
    let clause = format!(" TABLESPACE {tablespace}");
    let head = predicate.and_then(|predicate| statement.strip_suffix(&format!(" WHERE {predicate}")));
    match (head, predicate) {
        (Some(head), Some(predicate)) => format!("{head}{clause} WHERE {predicate}"),
        _ => format!("{statement}{clause}"),
    }
}

#[cfg(test)]
mod tests {
    use super::{in_tablespace, without_only};

    #[test]
    fn a_partitioned_index_is_built_on_every_partition() {
        assert_eq!(
            without_only(
                "CREATE UNIQUE INDEX \"Only\" ON ONLY public.p USING btree (k)".to_owned(),
                true,
                "\"Only\""
            ),
            "CREATE UNIQUE INDEX \"Only\" ON public.p USING btree (k)"
        );
        assert_eq!(
            without_only(
                "CREATE INDEX p_k ON ONLY public.p USING btree (k)".to_owned(),
                false,
                "p_k"
            ),
            "CREATE INDEX p_k ON public.p USING btree (k)"
        );
    }

    #[test]
    fn a_table_named_only_keeps_its_name() {
        let statement = "CREATE INDEX t_k ON public.only USING btree (k)".to_owned();

        assert_eq!(without_only(statement.clone(), false, "t_k"), statement);
    }

    #[test]
    fn the_tablespace_goes_before_the_predicate() {
        let partial = "CREATE INDEX t_k ON public.t USING btree (k) WITH (fillfactor='70') WHERE (k > 0)".to_owned();

        assert_eq!(
            in_tablespace(partial, "\"Fast\"", Some("(k > 0)")),
            "CREATE INDEX t_k ON public.t USING btree (k) WITH (fillfactor='70') TABLESPACE \"Fast\" WHERE (k > 0)"
        );
        assert_eq!(
            in_tablespace("CREATE INDEX t_k ON public.t USING btree (k)".to_owned(), "fast", None),
            "CREATE INDEX t_k ON public.t USING btree (k) TABLESPACE fast"
        );
    }
}
