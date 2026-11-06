use std::sync::Arc;

use scylla::response::query_result::ColumnSpecs;
use tablepro_core::DriverError;
use tablepro_core::column::ResultColumn;
use tablepro_core::edit::parsed_origins;
use tablepro_core::meta::TableRef;
use tablepro_core::sql_syntax::{SourceTable, SqlGrammar, source_table};

use crate::catalog::is_system_keyspace;
use crate::session::CqlLink;

// A materialized view is not in it: the view has a table of its own, which takes no writes.
const BASE_TABLE: &str = "SELECT table_name FROM system_schema.tables WHERE keyspace_name = ? AND table_name = ?";

// The RESULT metadata names the keyspace and table every column was read from, but a column by its alias or its
// function's text, so the statement says which columns are the table's own.
#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct SpecTable {
    statement: SourceTable,
    table: TableRef,
}

impl SpecTable {
    pub(crate) fn of(sql: &str, specs: ColumnSpecs<'_, '_>) -> Option<Self> {
        let statement = source_table(sql, SqlGrammar::Cql).ok()?;
        let mut tables = specs.iter().map(|spec| spec.table_spec());
        let first = tables.next()?;
        if tables.any(|table| table != first) {
            return None;
        }
        let (keyspace, name) = (first.ks_name(), first.table_name());
        if is_system_keyspace(keyspace) {
            return None;
        }
        Some(Self {
            statement,
            table: TableRef::new(Some(keyspace.to_owned()), name),
        })
    }

    pub(crate) async fn columns(&self, link: &CqlLink, columns: Arc<[ResultColumn]>) -> Arc<[ResultColumn]> {
        match self.is_base_table(link).await {
            Ok(true) => self.traced(&columns),
            Ok(false) => columns,
            Err(error) => {
                tracing::debug!(%error, "could not read where an editor result comes from");
                columns
            }
        }
    }

    async fn is_base_table(&self, link: &CqlLink) -> Result<bool, DriverError> {
        let keyspace = self.table.schema.as_deref().unwrap_or_default();
        let result = link.catalogue(BASE_TABLE, (keyspace, self.table.name.as_str())).await?;
        let rows = result
            .into_rows_result()
            .map_err(|error| DriverError::Protocol(error.to_string()))?;
        Ok(rows.rows_num() > 0)
    }

    fn traced(&self, columns: &[ResultColumn]) -> Arc<[ResultColumn]> {
        let names: Vec<String> = columns.iter().map(|column| column.name.clone()).collect();
        columns
            .iter()
            .zip(parsed_origins(&self.statement, &self.table, &names))
            .map(|(column, origin)| column.clone().with_origin(origin))
            .collect()
    }
}

#[cfg(test)]
mod tests {
    use tablepro_core::column::ColumnType;

    use super::*;

    #[test]
    fn an_alias_traces_to_the_column_it_names() {
        let spec = SpecTable {
            statement: source_table("SELECT a AS x, \"Some Col\", Id, writetime FROM t", SqlGrammar::Cql)
                .expect("one table"),
            table: TableRef::new(Some("shop".to_owned()), "t"),
        };
        let columns: Vec<ResultColumn> = ["x", "Some Col", "id", "writetime"]
            .iter()
            .map(|name| ResultColumn::new(*name, ColumnType::untyped_text("text")))
            .collect();

        let origins: Vec<Option<String>> = spec
            .traced(&columns)
            .iter()
            .map(|column| column.origin.as_ref().map(|origin| origin.column.clone()))
            .collect();

        assert_eq!(
            origins,
            ["a", "Some Col", "id", "writetime"].map(|name| Some(name.to_owned()))
        );
    }
}
