use tablepro_core::DriverError;
use tablepro_core::meta::TableInfo;
use tokio_postgres::Client;

use super::{decode_error, text_rows};

/// The relation's kind, its comment, and the sizes of what it stores:
/// its own for a table or materialized view, its leaf partitions' for a
/// partitioned table, which stores nothing itself. The leaves are found
/// through `pg_inherits`, which every release has; `pg_partition_tree`
/// came in 12 and finds the same ones.
pub(super) const TABLE_INFO_SQL: &str = "\
SELECT c.relkind::text,
       pg_catalog.obj_description(c.oid, 'pg_class'),
       sizes.data_bytes,
       sizes.index_bytes,
       sizes.total_bytes
FROM pg_catalog.pg_class c
CROSS JOIN LATERAL (
    WITH RECURSIVE tree AS (
        SELECT c.oid AS relid
      UNION ALL
        SELECT h.inhrelid FROM pg_catalog.pg_inherits h JOIN tree ON h.inhparent = tree.relid
         WHERE c.relkind = 'p'
    )
    SELECT COALESCE(pg_catalog.sum(pg_catalog.pg_table_size(leaf.oid)), 0)::int8,
           COALESCE(pg_catalog.sum(pg_catalog.pg_indexes_size(leaf.oid)), 0)::int8,
           COALESCE(pg_catalog.sum(pg_catalog.pg_total_relation_size(leaf.oid)), 0)::int8
    FROM tree
    JOIN pg_catalog.pg_class leaf ON leaf.oid = tree.relid
    WHERE leaf.relkind IN ('r', 'm')
) AS sizes(data_bytes, index_bytes, total_bytes)
WHERE c.oid = $1::text::oid";

pub(crate) async fn table_info(client: &Client, relation: &str) -> Result<TableInfo, DriverError> {
    let field = decode_error("pg_class");
    let rows = text_rows(client, TABLE_INFO_SQL, &[relation]).await?;
    let Some(row) = rows.first() else {
        return Ok(TableInfo::default());
    };
    let relkind: String = row.try_get(0).map_err(&field)?;
    let comment: Option<String> = row.try_get(1).map_err(&field)?;
    let data: i64 = row.try_get(2).map_err(&field)?;
    let index: i64 = row.try_get(3).map_err(&field)?;
    let total: i64 = row.try_get(4).map_err(&field)?;
    Ok(info(&relkind, comment, [data, index, total]))
}

// A view or a foreign table stores nothing here, so its sizes are no
// figure at all rather than zero.
fn info(relkind: &str, comment: Option<String>, [data, index, total]: [i64; 3]) -> TableInfo {
    let info = TableInfo::default().with_comment(comment);
    if !matches!(relkind, "r" | "m" | "p") {
        return info;
    }
    TableInfo {
        data_bytes: u64::try_from(data).ok(),
        index_bytes: u64::try_from(index).ok(),
        total_bytes: u64::try_from(total).ok(),
        ..info
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_view_keeps_its_comment_and_has_no_sizes() {
        let view = info("v", Some("seen".to_owned()), [0, 0, 0]);
        assert_eq!(view.comment.as_deref(), Some("seen"));
        assert_eq!(
            (view.data_bytes, view.index_bytes, view.total_bytes),
            (None, None, None)
        );
        assert_eq!(info("f", None, [0, 0, 0]), TableInfo::default());
    }

    #[test]
    fn a_table_reports_its_sizes_and_a_blank_comment_is_none() {
        let table = info("p", Some(" ".to_owned()), [8192, 16384, 24576]);
        assert_eq!(
            table,
            TableInfo {
                comment: None,
                data_bytes: Some(8192),
                index_bytes: Some(16384),
                total_bytes: Some(24576),
            }
        );
    }
}
