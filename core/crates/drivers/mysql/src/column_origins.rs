use std::sync::Arc;

use sqlx::mysql::{MySqlConnection, MySqlRow};
use sqlx::{AssertSqlSafe, Column as _, Executor as _, Row as _};
use tablepro_core::ResultEvent;
use tablepro_core::column::{ColumnOrigin, ResultColumn};
use tablepro_core::meta::TableRef;
use tablepro_core::sql_syntax::SourceTable;

use crate::dialect::quote;

// performance_schema's tables show as CREATE TABLE, and no row of theirs is a stored one.
const SYSTEM_SCHEMAS: [&str; 2] = ["information_schema", "performance_schema"];

#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct TracedSet {
    set_index: usize,
    columns: Arc<[ResultColumn]>,
    // As sqlx gives it: the schema and table joined with an unquoted dot, and the column.
    wire: Vec<Option<(Arc<str>, Arc<str>)>>,
    statement: SourceTable,
}

impl TracedSet {
    pub(crate) fn new(set_index: usize, columns: Arc<[ResultColumn]>, row: &MySqlRow, statement: SourceTable) -> Self {
        let wire = row
            .columns()
            .iter()
            .map(|column| {
                column
                    .origin()
                    .table_column()
                    .map(|origin| (origin.table.clone(), origin.name.clone()))
            })
            .collect();
        Self {
            set_index,
            columns,
            wire,
            statement,
        }
    }
}

// A merge view names itself, a TEMPTABLE view its base table, and a temporary table looks like the base table it shadows, so SHOW CREATE TABLE on the name the statement read decides.
pub(crate) async fn resolved_columns(connection: &mut MySqlConnection, set: TracedSet) -> Option<ResultEvent> {
    let origins: Vec<Option<ColumnOrigin>> = set
        .wire
        .iter()
        .map(|wire| {
            wire.as_ref()
                .and_then(|(table, column)| origin(&set.statement.table, table, column))
        })
        .collect();
    let mut tables = origins.iter().flatten().map(|origin| &origin.table);
    let first = tables.next()?;
    if tables.any(|table| table != first) || !permanent_table(connection, &set.statement.table).await {
        return None;
    }
    let columns = set
        .columns
        .iter()
        .zip(origins)
        .map(|(column, origin)| column.clone().with_origin(origin))
        .collect();
    Some(ResultEvent::ColumnsResolved {
        set_index: set.set_index,
        columns,
    })
}

// The name the statement wrote splits the joined text, whatever dots the schema or table holds.
fn origin(statement: &TableRef, wire: &str, column: &str) -> Option<ColumnOrigin> {
    let schema_end = wire.len().checked_sub(statement.name.len() + 1)?;
    let schema = wire.get(..schema_end)?;
    let table = wire.get(schema_end..)?.strip_prefix('.')?;
    let named = table.eq_ignore_ascii_case(&statement.name)
        && statement
            .schema
            .as_ref()
            .is_none_or(|written| written.eq_ignore_ascii_case(schema));
    let system = SYSTEM_SCHEMAS.iter().any(|system| system.eq_ignore_ascii_case(schema));
    (named && !system && !schema.is_empty() && !column.is_empty())
        .then(|| ColumnOrigin::new(TableRef::new(Some(schema.to_owned()), table), column))
}

async fn permanent_table(connection: &mut MySqlConnection, table: &TableRef) -> bool {
    let name = match &table.schema {
        Some(schema) => format!("{}.{}", quote(schema), quote(&table.name)),
        None => quote(&table.name),
    };
    let shown = connection
        .fetch_all(sqlx::raw_sql(AssertSqlSafe(format!("SHOW CREATE TABLE {name}"))))
        .await;
    let rows = match shown {
        Ok(rows) => rows,
        Err(error) => {
            tracing::debug!(%error, "the result's table was not shown");
            return false;
        }
    };
    let definition = rows
        .first()
        .and_then(|row| row.try_get_unchecked::<Option<&[u8]>, _>(1).ok().flatten());
    // A temporary table, a view and a MariaDB sequence each show otherwise.
    definition
        .map(String::from_utf8_lossy)
        .is_some_and(|definition| definition.starts_with("CREATE TABLE ") && !definition.contains(" SEQUENCE=1"))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn traced(schema: &str, table: &str, column: &str) -> Option<ColumnOrigin> {
        Some(ColumnOrigin::new(TableRef::new(Some(schema.to_owned()), table), column))
    }

    #[test]
    fn the_written_name_splits_a_dotted_schema_or_table() {
        let unqualified = TableRef::unqualified("t");
        let dotted = TableRef::unqualified("b.c");

        assert_eq!(origin(&unqualified, "p.t", "id"), traced("p", "t", "id"));
        assert_eq!(origin(&unqualified, "a.b.t", "id"), traced("a.b", "t", "id"));
        assert_eq!(origin(&dotted, "a.b.c", "id"), traced("a", "b.c", "id"));
        assert_eq!(
            origin(&TableRef::new(Some("P".to_owned()), "T"), "p.t", "id"),
            traced("p", "t", "id")
        );
    }

    #[test]
    fn another_table_a_bare_name_or_a_system_schema_has_no_origin() {
        let unqualified = TableRef::unqualified("vt");

        assert_eq!(origin(&unqualified, "p.t", "id"), None);
        assert_eq!(origin(&TableRef::unqualified("t"), "t", "id"), None);
        assert_eq!(origin(&TableRef::new(Some("q".to_owned()), "t"), "p.t", "id"), None);
        assert_eq!(
            origin(
                &TableRef::unqualified("accounts"),
                "performance_schema.accounts",
                "USER"
            ),
            None
        );
    }
}
