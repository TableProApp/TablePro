use postgres_protocol::escape::escape_identifier;
use tablepro_core::DriverError;
use tablepro_core::column::ColumnOrigin;
use tablepro_core::edit::parsed_origins;
use tablepro_core::meta::TableRef;
use tablepro_core::sql_syntax::{SourceTable, SqlGrammar, source_table};
use tokio_postgres::Client;

use super::editor_dispatch::CursorOwner;
use crate::metadata::{decode_error, text_rows};

pub(super) const SAVEPOINT: &str = "SAVEPOINT tablepro_origin_savepoint";
pub(super) const RELEASE_SAVEPOINT: &str = "RELEASE SAVEPOINT tablepro_origin_savepoint";
pub(super) const ROLLBACK_TO_SAVEPOINT: &str =
    "ROLLBACK TO SAVEPOINT tablepro_origin_savepoint; RELEASE SAVEPOINT tablepro_origin_savepoint";

// The open cursor holds a lock on the relation its statement read, so a relation of the same name
// created since the DECLARE is not taken for it.
const ORIGIN_SQL: &str = "\
SELECT n.nspname::text, c.relname::text, a.attname::text
FROM pg_catalog.pg_class c
JOIN pg_catalog.pg_namespace n ON n.oid = c.relnamespace
JOIN pg_catalog.pg_attribute a ON a.attrelid = c.oid AND a.attnum > 0 AND NOT a.attisdropped
WHERE c.oid = pg_catalog.to_regclass($1)
  AND c.relkind IN ('r', 'p')
  AND c.relpersistence IN ('p', 'u')
  AND n.nspname <> 'information_schema'
  AND NOT pg_catalog.starts_with(n.nspname, 'pg_')
  AND EXISTS (
      SELECT 1 FROM pg_catalog.pg_locks l
      WHERE l.locktype = 'relation' AND l.relation = c.oid AND l.pid = pg_catalog.pg_backend_pid()
  )
ORDER BY a.attnum";

pub(super) struct TracedTable {
    statement: SourceTable,
    table: TableRef,
    columns: Vec<String>,
}

impl TracedTable {
    pub(super) fn origins(&self, names: &[String]) -> Vec<Option<ColumnOrigin>> {
        parsed_origins(&self.statement, &self.table, names)
            .into_iter()
            .map(|origin| origin.filter(|origin| self.columns.contains(&origin.column)))
            .collect()
    }
}

// Inside the user's transaction a failed lookup would abort it, so only the driver's own transaction is traced.
pub(super) fn traceable(text: &str, owner: CursorOwner) -> Option<SourceTable> {
    match owner {
        CursorOwner::Driver { .. } => source_table(text, SqlGrammar::PostgreSql).ok(),
        CursorOwner::Savepoint => None,
    }
}

// tokio-postgres would prepare a lookup of any non-built-in column type under a name, so the statement is not
// described; its table is resolved instead, with every projected type built in.
pub(super) async fn lookup(client: &Client, statement: SourceTable) -> Result<Option<TracedTable>, DriverError> {
    let relation = relation(&statement.table);
    let rows = text_rows(client, ORIGIN_SQL, &[relation.as_str()]).await?;
    let Some(first) = rows.first() else {
        return Ok(None);
    };
    let field = decode_error("pg_attribute");
    let schema: String = first.try_get(0).map_err(&field)?;
    let name: String = first.try_get(1).map_err(&field)?;
    let columns = rows
        .iter()
        .map(|row| row.try_get(2).map_err(&field))
        .collect::<Result<Vec<String>, _>>()?;
    Ok(Some(TracedTable {
        statement,
        table: TableRef::new(Some(schema), name),
        columns,
    }))
}

fn relation(table: &TableRef) -> String {
    match table.schema.as_deref() {
        Some(schema) => format!("{}.{}", escape_identifier(schema), escape_identifier(&table.name)),
        None => escape_identifier(&table.name),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const DRIVER: CursorOwner = CursorOwner::Driver { read_only: false };

    fn traced(sql: &str, columns: &[&str]) -> TracedTable {
        TracedTable {
            statement: traceable(sql, DRIVER).expect("one table"),
            table: TableRef::new(Some("public".to_owned()), "t"),
            columns: columns.iter().map(|column| (*column).to_owned()).collect(),
        }
    }

    fn columns(origins: &[Option<ColumnOrigin>]) -> Vec<Option<&str>> {
        origins
            .iter()
            .map(|origin| origin.as_ref().map(|origin| origin.column.as_str()))
            .collect()
    }

    fn names(names: &[&str]) -> Vec<String> {
        names.iter().map(|name| (*name).to_owned()).collect()
    }

    #[test]
    fn only_a_one_table_select_in_the_drivers_own_transaction_is_traced() {
        assert!(traceable("SELECT * FROM t", DRIVER).is_some());
        assert!(traceable("SELECT * FROM t", CursorOwner::Driver { read_only: true }).is_some());
        assert!(traceable("SELECT * FROM t", CursorOwner::Savepoint).is_none());
        assert!(traceable("SELECT t.id, u.c FROM t JOIN u ON u.t_id = t.id", DRIVER).is_none());
        assert!(traceable("SELECT count(*) FROM t", DRIVER).is_none());
    }

    #[test]
    fn a_column_the_table_lacks_has_no_origin() {
        let table = traced("SELECT ctid, id, a AS x, id + 1 FROM t", &["id", "a"]);

        let origins = table.origins(&names(&["ctid", "id", "x", "?column?"]));

        assert_eq!(columns(&origins), vec![None, Some("id"), Some("a"), None]);
        assert!(origins.iter().flatten().all(|origin| origin.table == table.table));
    }

    #[test]
    fn a_wildcard_traces_the_columns_it_read() {
        let table = traced("SELECT *, 1 AS one FROM t", &["id", "a"]);

        let origins = table.origins(&names(&["id", "a", "one"]));

        assert_eq!(columns(&origins), vec![Some("id"), Some("a"), None]);
    }

    #[test]
    fn a_bare_value_keyword_is_never_the_column_of_that_name() {
        let table = traced(
            "SELECT current_role, \"current_role\", CURRENT_SCHEMA, id FROM t",
            &["current_role", "current_schema", "id"],
        );

        let origins = table.origins(&names(&["current_role", "current_role", "current_schema", "id"]));

        assert_eq!(columns(&origins), vec![None, Some("current_role"), None, Some("id")]);
    }

    #[test]
    fn the_relation_is_quoted_as_the_statement_resolved_it() {
        assert_eq!(
            relation(&TableRef::new(Some("Other".to_owned()), "my\"t")),
            "\"Other\".\"my\"\"t\""
        );
        assert_eq!(relation(&TableRef::unqualified("t")), "\"t\"");
    }
}
