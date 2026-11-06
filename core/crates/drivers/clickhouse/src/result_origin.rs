use std::sync::Arc;

use tablepro_core::Value;
use tablepro_core::column::ResultColumn;
use tablepro_core::edit::parsed_origins;
use tablepro_core::meta::TableRef;
use tablepro_core::sql_syntax::{SourceTable, SqlGrammar, source_table};
use uuid::Uuid;

use crate::result_reader::{CatalogRow, read_table};

// ClickHouse reports no origin, so the session that runs the statement is asked how it resolves the name: an
// unqualified one is a temporary table of the session's first, then a table of its current database. Only the two
// databases that can hold the name are listed, so no other database's engine is asked for its tables. The answer is one
// row, which a `limit` the session set cannot cut short.
const LOOKUP: &str = "SELECT countIf(is_temporary), groupArrayIf(database, NOT is_temporary), \
     groupArrayIf(engine, NOT is_temporary), \
     (SELECT groupArray(name) FROM system.columns \
      WHERE database = if({db:String} = '', currentDatabase(), {db:String}) AND table = {tbl:String}) \
     FROM system.tables \
     WHERE name = {tbl:String} AND database IN ('', if({db:String} = '', currentDatabase(), {db:String}))";

#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct TracedTable {
    statement: SourceTable,
    table: TableRef,
    columns: Vec<String>,
}

impl TracedTable {
    pub(crate) fn columns(&self, columns: Arc<[ResultColumn]>) -> Arc<[ResultColumn]> {
        let names: Vec<String> = columns.iter().map(|column| column.name.clone()).collect();
        let origins = parsed_origins(&self.statement, &self.table, &names);
        columns
            .iter()
            .zip(origins)
            .map(|(column, origin)| {
                // A virtual column such as `_part` is read from the table but is none of its columns.
                let origin = origin.filter(|origin| self.columns.contains(&origin.column));
                column.clone().with_origin(origin)
            })
            .collect()
    }
}

pub(crate) fn with_origins(traced: Option<&TracedTable>, columns: Arc<[ResultColumn]>) -> Arc<[ResultColumn]> {
    match traced {
        Some(traced) => traced.columns(columns),
        None => columns,
    }
}

pub(crate) fn source(sql: &str) -> Option<SourceTable> {
    source_table(sql, SqlGrammar::ClickHouse).ok()
}

// Sent on the editor's session before the statement, which the server would refuse while the session runs another.
pub(crate) async fn traced_table(
    session: &clickhouse::Client,
    statement: SourceTable,
    query_id: Uuid,
) -> Option<TracedTable> {
    let query = session
        .query_raw(LOOKUP)
        .with_setting("query_id", query_id.to_string())
        .param("db", statement.table.schema.as_deref().unwrap_or_default())
        .param("tbl", statement.table.name.as_str());
    let rows = match read_table(query, None).await {
        Ok(result) => result.rows,
        Err(error) => {
            tracing::debug!(%error, "could not read where an editor result comes from");
            return None;
        }
    };
    let (table, columns) = resolve(&statement.table, rows.first()?)?;
    Some(TracedTable {
        statement,
        table,
        columns,
    })
}

fn resolve(written: &TableRef, row: &[Value]) -> Option<(TableRef, Vec<String>)> {
    let row = CatalogRow(row);
    // A temporary table of the name is the one an unqualified name reads.
    if row.flag(0).ok()? {
        return None;
    }
    let [database] = <[String; 1]>::try_from(row.texts(1).ok()?).ok()?;
    let [engine] = <[String; 1]>::try_from(row.texts(2).ok()?).ok()?;
    let columns = row.texts(3).ok()?;
    edits_rows(&engine).then(|| (TableRef::new(Some(database), written.name.clone()), columns))
}

// The table tab keys a row by its sorting key and writes it as a mutation, which only the MergeTree family has. Views,
// dictionaries, system tables and engines that hold another server's rows are left out with them.
fn edits_rows(engine: &str) -> bool {
    engine.ends_with("MergeTree")
}

#[cfg(test)]
mod tests {
    use tablepro_core::column::{ColumnOrigin, ColumnType};

    use super::*;

    fn texts(texts: &[&str]) -> Value {
        Value::Array(texts.iter().map(|text| Value::Text((*text).to_owned())).collect())
    }

    fn row(temporaries: u64, databases: &[&str], engines: &[&str]) -> Vec<Value> {
        vec![
            Value::UInt(temporaries),
            texts(databases),
            texts(engines),
            texts(&["id", "a"]),
        ]
    }

    #[test]
    fn only_one_mergetree_table_of_the_name_is_traced() {
        let written = TableRef::unqualified("t");

        assert_eq!(
            resolve(&written, &row(0, &["shop"], &["ReplicatedMergeTree"])),
            Some((
                TableRef::new(Some("shop".to_owned()), "t"),
                vec!["id".to_owned(), "a".to_owned()]
            ))
        );
        assert_eq!(resolve(&written, &row(1, &["shop"], &["MergeTree"])), None);
        assert_eq!(resolve(&written, &row(0, &[], &[])), None);
        for engine in [
            "View",
            "MaterializedView",
            "Dictionary",
            "Memory",
            "MySQL",
            "Distributed",
        ] {
            assert_eq!(resolve(&written, &row(0, &["shop"], &[engine])), None, "{engine}");
        }
    }

    #[test]
    fn origins_name_only_the_tables_own_columns() {
        let traced = TracedTable {
            statement: source("SELECT _part, a AS x, *, id + 1 FROM t").expect("one table"),
            table: TableRef::new(Some("shop".to_owned()), "t"),
            columns: vec!["id".to_owned(), "a".to_owned()],
        };
        let result: Arc<[ResultColumn]> = ["_part", "x", "id", "a", "plus(id, 1)"]
            .iter()
            .map(|name| ResultColumn::new(*name, ColumnType::untyped_text("String")))
            .collect();

        let origins: Vec<Option<ColumnOrigin>> = traced
            .columns(result)
            .iter()
            .map(|column| column.origin.clone())
            .collect();

        let origin = |column: &str| Some(ColumnOrigin::new(TableRef::new(Some("shop".to_owned()), "t"), column));
        assert_eq!(origins, vec![None, origin("a"), origin("id"), origin("a"), None]);
    }
}
