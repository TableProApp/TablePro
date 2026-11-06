use tablepro_core::DriverError;
use tablepro_core::column::ColumnOrigin;
use tablepro_core::edit::parsed_origins;
use tablepro_core::meta::TableRef;
use tablepro_core::sql_syntax::{SourceTable, SqlGrammar, source_table};

use crate::errors::map_error;
use crate::instance::Link;

// DuckDB reports no origin, so one query reads what its binder resolves the name against: the session's database,
// schema and search path, a temporary object or a catalogue the name could mean instead, and each base table of that
// name with its columns. Names compare case-insensitively, as DuckDB's catalogue does.
const LOOKUP: &str = "SELECT 'scope', current_database(), current_schema(), current_setting('search_path'), NULL \
     UNION ALL \
     SELECT 'catalog', database_name, NULL, NULL, NULL FROM duckdb_databases() \
     WHERE lower(database_name) = lower(?) \
     UNION ALL \
     SELECT 'temporary', database_name, schema_name, table_name, NULL FROM duckdb_tables() \
     WHERE temporary AND lower(table_name) = lower(?) \
     UNION ALL \
     SELECT 'temporary', database_name, schema_name, view_name, NULL FROM duckdb_views() \
     WHERE temporary AND lower(view_name) = lower(?) \
     UNION ALL \
     SELECT 'column', t.database_name, t.schema_name, t.table_name, c.column_name \
     FROM duckdb_tables() AS t \
     JOIN duckdb_columns() AS c ON c.database_oid = t.database_oid AND c.table_oid = t.table_oid \
     WHERE NOT t.temporary AND lower(t.table_name) = lower(?)";

#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct TracedTable {
    statement: SourceTable,
    table: TableRef,
    columns: Vec<String>,
}

impl TracedTable {
    pub(crate) fn origins(&self, names: &[String]) -> Vec<Option<ColumnOrigin>> {
        parsed_origins(&self.statement, &self.table, names)
            .into_iter()
            .map(|origin| origin.and_then(|origin| self.cataloged(origin)))
            .collect()
    }

    // DuckDB also binds names the table has no column for, such as `rowid`.
    fn cataloged(&self, origin: ColumnOrigin) -> Option<ColumnOrigin> {
        let mut named = self
            .columns
            .iter()
            .filter(|column| column.eq_ignore_ascii_case(&origin.column));
        match (named.next(), named.next()) {
            (Some(column), None) => Some(ColumnOrigin::new(origin.table, column.clone())),
            _ => None,
        }
    }
}

// Asked before the statement: a query on the connection would close the statement's streaming result.
pub(crate) fn traced_table(link: &Link, catalog: &str, sql: &str) -> Option<TracedTable> {
    let statement = source_table(sql, SqlGrammar::DuckDb).ok()?;
    let found = match lookup(link, &statement.table) {
        Ok(found) => found,
        Err(error) => {
            tracing::debug!(%error, "could not read where an editor result comes from");
            return None;
        }
    };
    let (table, columns) = resolve(catalog, &statement.table, &found)?;
    Some(TracedTable {
        statement,
        table,
        columns,
    })
}

#[derive(Debug, Clone, PartialEq, Eq)]
enum Found {
    Scope {
        database: String,
        schema: String,
        search_path: String,
    },
    Catalog,
    Temporary,
    Column {
        database: String,
        schema: String,
        table: String,
        column: String,
    },
}

fn lookup(link: &Link, written: &TableRef) -> Result<Vec<Found>, DriverError> {
    let schema = written.schema.as_deref().unwrap_or_default();
    let name = written.name.as_str();
    let mut statement = link.connection.prepare(LOOKUP).map_err(map_error)?;
    let mut rows = statement
        .query(duckdb::params![schema, name, name, name])
        .map_err(map_error)?;
    let mut found = Vec::new();
    while let Some(row) = rows.next().map_err(map_error)? {
        let cell = |index: usize| {
            row.get::<_, Option<String>>(index)
                .map(Option::unwrap_or_default)
                .map_err(map_error)
        };
        found.push(match cell(0)?.as_str() {
            "scope" => Found::Scope {
                database: cell(1)?,
                schema: cell(2)?,
                search_path: cell(3)?,
            },
            "catalog" => Found::Catalog,
            "temporary" => Found::Temporary,
            _ => Found::Column {
                database: cell(1)?,
                schema: cell(2)?,
                table: cell(3)?,
                column: cell(4)?,
            },
        });
    }
    Ok(found)
}

// The table tab names the file's tables by schema and table, and the dialect puts the file's catalogue in front, so
// only a table of that catalogue is traced.
fn resolve(catalog: &str, written: &TableRef, found: &[Found]) -> Option<(TableRef, Vec<String>)> {
    let (database, current_schema, search_path) = found.iter().find_map(|found| match found {
        Found::Scope {
            database,
            schema,
            search_path,
        } => Some((database, schema, search_path)),
        _ => None,
    })?;
    // A temporary object comes first even for `main.t`, and with more than one search path entry a name can resolve
    // past the current schema or to another catalogue's schema.
    if !database.eq_ignore_ascii_case(catalog) || search_path.contains(',') || found.contains(&Found::Temporary) {
        return None;
    }
    let schema = match &written.schema {
        // DuckDB reads `a.t` as catalogue `a` when there is one.
        Some(_) if found.contains(&Found::Catalog) => return None,
        Some(schema) => schema,
        None => current_schema,
    };
    let mut table: Option<TableRef> = None;
    let mut columns = Vec::new();
    for entry in found {
        let Found::Column {
            database,
            schema: column_schema,
            table: column_table,
            column,
        } = entry
        else {
            continue;
        };
        if !database.eq_ignore_ascii_case(catalog)
            || !column_schema.eq_ignore_ascii_case(schema)
            || !column_table.eq_ignore_ascii_case(&written.name)
        {
            continue;
        }
        let named = TableRef::new(Some(column_schema.clone()), column_table.clone());
        match &table {
            Some(seen) if *seen != named => return None,
            _ => table = Some(named),
        }
        columns.push(column.clone());
    }
    Some((table?, columns))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn scope(schema: &str, search_path: &str) -> Found {
        Found::Scope {
            database: "sales".to_owned(),
            schema: schema.to_owned(),
            search_path: search_path.to_owned(),
        }
    }

    fn column(database: &str, schema: &str, table: &str, column: &str) -> Found {
        Found::Column {
            database: database.to_owned(),
            schema: schema.to_owned(),
            table: table.to_owned(),
            column: column.to_owned(),
        }
    }

    fn orders() -> Vec<Found> {
        vec![
            scope("main", ""),
            column("sales", "main", "Orders", "id"),
            column("sales", "main", "Orders", "total"),
            column("sales", "audit", "Orders", "id"),
            column("archive", "main", "Orders", "id"),
        ]
    }

    #[test]
    fn a_name_resolves_to_the_catalogs_spelling_in_the_current_schema() {
        let resolved = resolve("sales", &TableRef::unqualified("orders"), &orders());

        assert_eq!(
            resolved,
            Some((
                TableRef::new(Some("main".to_owned()), "Orders"),
                vec!["id".to_owned(), "total".to_owned()]
            ))
        );
        let audit = resolve("sales", &TableRef::new(Some("AUDIT".to_owned()), "orders"), &orders());
        assert_eq!(audit.map(|(table, _)| table.schema), Some(Some("audit".to_owned())));
    }

    #[test]
    fn a_name_that_may_mean_something_else_is_not_traced() {
        let mut shadowed = orders();
        shadowed.push(Found::Temporary);
        assert_eq!(resolve("sales", &TableRef::unqualified("orders"), &shadowed), None);

        let mut catalog = orders();
        catalog.push(Found::Catalog);
        assert_eq!(
            resolve("sales", &TableRef::new(Some("archive".to_owned()), "orders"), &catalog),
            None
        );

        let mut searched = orders();
        searched[0] = scope("main", "sales.main,archive.main");
        assert_eq!(resolve("sales", &TableRef::unqualified("orders"), &searched), None);

        assert_eq!(resolve("archive", &TableRef::unqualified("orders"), &orders()), None);
        assert_eq!(resolve("sales", &TableRef::unqualified("missing"), &orders()), None);
    }

    #[test]
    fn origins_name_only_columns_the_table_has() {
        let traced = TracedTable {
            statement: source_table("SELECT ROWID, ID AS k, *, total + 1 FROM orders", SqlGrammar::DuckDb)
                .expect("one table"),
            table: TableRef::new(Some("main".to_owned()), "Orders"),
            columns: vec!["id".to_owned(), "total".to_owned()],
        };
        let names = ["rowid", "k", "id", "total", "(total + 1)"].map(str::to_owned);

        let columns: Vec<Option<String>> = traced
            .origins(&names)
            .into_iter()
            .map(|origin| origin.map(|origin| origin.column))
            .collect();

        assert_eq!(
            columns,
            vec![
                None,
                Some("id".to_owned()),
                Some("id".to_owned()),
                Some("total".to_owned()),
                None
            ]
        );
    }
}
