use std::ffi::{CStr, CString, c_char};

use sqlx::sqlite::{LockedSqliteHandle, SqliteConnection as SqlxConnection};
use tablepro_core::column::ColumnOrigin;
use tablepro_core::meta::TableRef;
use tablepro_core::sql_syntax::{SqlGrammar, source_table};

use crate::autocommit::is_autocommit;
use crate::catalog::MAIN_SCHEMA;

const TEMP_SCHEMA: &str = "temp";

struct NamedColumn {
    database: String,
    table: String,
    column: String,
}

// sqlx joins the database and table with an unquoted dot, so table `a.b` in main reads as table `b` in `a`; SQLite's own calls keep them apart.
pub(crate) async fn column_origins(connection: &mut SqlxConnection, sql: &str) -> Option<Vec<Option<ColumnOrigin>>> {
    let statement = source_table(sql, SqlGrammar::Sqlite).ok()?;
    let table = CString::new(statement.table.name.as_str()).ok()?;
    let schema = statement.table.schema.as_deref().map(CString::new).transpose().ok()?;
    let mut handle = connection.lock_handle().await.ok()?;
    if !is_autocommit(&mut handle) || !names_a_table(&mut handle, schema.as_deref(), &table) {
        return None;
    }
    let named = named_columns(&mut handle, sql)?;
    Some(
        named
            .into_iter()
            .map(|named| named.and_then(|named| origin(named, &statement.table)))
            .collect(),
    )
}

// A view reports its base table's origins, so the statement's own name has to resolve, as SQLite resolves it, to a table.
fn names_a_table(handle: &mut LockedSqliteHandle<'_>, schema: Option<&CStr>, table: &CStr) -> bool {
    let raw = handle.as_raw_handle().as_ptr();
    // SAFETY: `raw` comes from the locked handle, so the connection is
    // open and nothing runs on it meanwhile. Both names are
    // NUL-terminated and outlive the call; every output may be NULL.
    // The statement was just compiled, so the schema is loaded.
    let code = unsafe {
        libsqlite3_sys::sqlite3_table_column_metadata(
            raw,
            schema.map_or(std::ptr::null(), CStr::as_ptr),
            table.as_ptr(),
            std::ptr::null(),
            std::ptr::null_mut(),
            std::ptr::null_mut(),
            std::ptr::null_mut(),
            std::ptr::null_mut(),
            std::ptr::null_mut(),
        )
    };
    code == libsqlite3_sys::SQLITE_OK
}

fn named_columns(handle: &mut LockedSqliteHandle<'_>, sql: &str) -> Option<Vec<Option<NamedColumn>>> {
    let raw = handle.as_raw_handle().as_ptr();
    let length = std::ffi::c_int::try_from(sql.len()).ok()?;
    let mut statement = std::ptr::null_mut();
    // SAFETY: `raw` is the locked, open connection; `sql` outlives the
    // call and `length` is its length, so SQLite reads inside it.
    let code = unsafe {
        libsqlite3_sys::sqlite3_prepare_v2(raw, sql.as_ptr().cast(), length, &mut statement, std::ptr::null_mut())
    };
    if statement.is_null() {
        return None;
    }
    // SAFETY: `statement` was prepared above and is finalized after the
    // last read; the names SQLite returns stay valid until then.
    let named = unsafe {
        let text = |name: *const c_char| match name.is_null() {
            true => None,
            false => CStr::from_ptr(name).to_str().ok().map(str::to_owned),
        };
        let named: Vec<Option<NamedColumn>> = (0..libsqlite3_sys::sqlite3_column_count(statement))
            .map(|index| {
                Some(NamedColumn {
                    database: text(libsqlite3_sys::sqlite3_column_database_name(statement, index))?,
                    table: text(libsqlite3_sys::sqlite3_column_table_name(statement, index))?,
                    column: text(libsqlite3_sys::sqlite3_column_origin_name(statement, index))?,
                })
            })
            .collect();
        libsqlite3_sys::sqlite3_finalize(statement);
        named
    };
    (code == libsqlite3_sys::SQLITE_OK).then_some(named)
}

// A temp table lives on this connection only, and `sqlite_` names are SQLite's own tables.
fn origin(named: NamedColumn, statement: &TableRef) -> Option<ColumnOrigin> {
    let internal = named
        .table
        .get(..7)
        .is_some_and(|prefix| prefix.eq_ignore_ascii_case("sqlite_"));
    let written = statement
        .schema
        .as_ref()
        .is_none_or(|schema| schema.eq_ignore_ascii_case(&named.database));
    if named.database == TEMP_SCHEMA || internal || !written || !named.table.eq_ignore_ascii_case(&statement.name) {
        return None;
    }
    let schema = (named.database != MAIN_SCHEMA).then_some(named.database);
    Some(ColumnOrigin::new(TableRef::new(schema, named.table), named.column))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn named(database: &str, table: &str, column: &str) -> NamedColumn {
        NamedColumn {
            database: database.to_owned(),
            table: table.to_owned(),
            column: column.to_owned(),
        }
    }

    #[test]
    fn main_carries_no_schema_and_an_attached_database_its_name() {
        let unqualified = TableRef::unqualified("t");

        assert_eq!(
            origin(named("main", "t", "id"), &unqualified),
            Some(ColumnOrigin::new(TableRef::unqualified("t"), "id"))
        );
        assert_eq!(
            origin(named("other", "t", "id"), &unqualified),
            Some(ColumnOrigin::new(TableRef::new(Some("other".to_owned()), "t"), "id"))
        );
        assert_eq!(
            origin(named("main", "a.b", "id"), &TableRef::unqualified("a.b")),
            Some(ColumnOrigin::new(TableRef::unqualified("a.b"), "id"))
        );
    }

    #[test]
    fn temp_internal_and_other_tables_have_no_origin() {
        let unqualified = TableRef::unqualified("t");

        assert_eq!(origin(named("temp", "t", "id"), &unqualified), None);
        assert_eq!(
            origin(
                named("main", "sqlite_master", "name"),
                &TableRef::unqualified("sqlite_master")
            ),
            None
        );
        assert_eq!(origin(named("main", "u", "id"), &unqualified), None);
        assert_eq!(
            origin(named("main", "t", "id"), &TableRef::new(Some("other".to_owned()), "t")),
            None
        );
    }
}
