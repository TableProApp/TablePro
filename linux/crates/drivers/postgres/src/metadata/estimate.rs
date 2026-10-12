use tablepro_core::DriverError;
use tablepro_core::meta::{RowCountEstimate, TableEstimate};
use tokio_postgres::Client;

use super::{decode_error, text_rows};

/// The planner's row count summed over the table and every descendant,
/// so a partitioned or inherited table counts its children. A table never
/// analysed has `reltuples` -1 from PostgreSQL 14 on (0 before), which is
/// no estimate at all. The heap size in blocks is what sizes a ctid
/// window.
const ESTIMATE_SQL: &str = "\
WITH RECURSIVE tree AS (
    SELECT $1::text::regclass::oid AS oid
  UNION
    SELECT i.inhrelid FROM pg_catalog.pg_inherits i JOIN tree t ON i.inhparent = t.oid
)
SELECT COALESCE(SUM(GREATEST(c.reltuples, 0)), 0)::float8,
       COALESCE(bool_and(c.reltuples < 0), true),
       (pg_catalog.pg_relation_size($1::text::regclass)
          / current_setting('block_size')::int8)::int8
FROM tree
JOIN pg_catalog.pg_class c ON c.oid = tree.oid";

pub(crate) async fn table_estimate(client: &Client, relation: &str) -> Result<TableEstimate, DriverError> {
    let field = decode_error("pg_class");
    let rows = text_rows(client, ESTIMATE_SQL, &[relation]).await?;
    let Some(row) = rows.first() else {
        return Ok(TableEstimate {
            rows: RowCountEstimate::Unknown,
            heap_blocks: None,
        });
    };
    let tuples: f64 = row.try_get(0).map_err(&field)?;
    let never_analysed: bool = row.try_get(1).map_err(&field)?;
    let blocks: i64 = row.try_get(2).map_err(&field)?;
    Ok(TableEstimate {
        rows: estimate(tuples, never_analysed),
        heap_blocks: u64::try_from(blocks).ok(),
    })
}

fn estimate(tuples: f64, never_analysed: bool) -> RowCountEstimate {
    if never_analysed || !tuples.is_finite() {
        return RowCountEstimate::Unknown;
    }
    // reltuples is a float the planner rounds anyway, so the nearest
    // whole row is all the precision it carries; the cast saturates.
    RowCountEstimate::Approximate(tuples.round().max(0.0) as u64)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn an_unanalysed_table_has_no_estimate() {
        assert_eq!(estimate(0.0, true), RowCountEstimate::Unknown);
        assert_eq!(estimate(1234.4, false), RowCountEstimate::Approximate(1234));
        assert_eq!(estimate(f64::NAN, false), RowCountEstimate::Unknown);
    }
}
