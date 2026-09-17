use std::str::FromStr;
use std::time::Duration;

use async_trait::async_trait;
use sqlx::sqlite::{SqliteConnectOptions, SqlitePoolOptions, SqliteRow};
use sqlx::{AssertSqlSafe, Column, Pool, Row, Sqlite, TypeInfo, ValueRef};

use futures::stream::StreamExt;

use tablepro_core::column::{
    CatalogType, ColumnDefault, ColumnType, ReadForm, ResultColumn, SqlExpression, SqlTypeExpr, classify_type_name,
    has_dynamic_storage,
};
use tablepro_core::value::{SqlTime, Temporal};
use tablepro_core::{
    ColumnInfo, ConnectOptions, Connection, DatabaseDriver, DriverError, ExecResult, ForeignKeyInfo, IndexInfo,
    LossPhase, MAX_QUERY_ROWS, QueryResult, ReadOnlyRefusal, ServerCode, ServerDiagnostics, TableInfo, Value,
};

pub struct SqliteDriver;

#[async_trait]
impl DatabaseDriver for SqliteDriver {
    fn id(&self) -> &'static str {
        "sqlite"
    }

    fn display_name(&self) -> &'static str {
        "SQLite"
    }

    fn default_port(&self) -> u16 {
        0
    }

    fn is_file_based(&self) -> bool {
        true
    }

    fn ddl_is_transactional(&self) -> bool {
        true
    }

    async fn connect(&self, opts: ConnectOptions) -> Result<Box<dyn Connection>, DriverError> {
        let url = if opts.database.is_empty() || opts.database == ":memory:" {
            "sqlite::memory:".to_string()
        } else {
            format!("sqlite:{}", opts.database)
        };
        let path = std::path::PathBuf::from(&opts.database);
        let connect_opts = SqliteConnectOptions::from_str(&url)
            .map_err(|error| map_file_error(error, &path))?
            .create_if_missing(true);
        let pool = SqlitePoolOptions::new()
            .max_connections(4)
            .acquire_timeout(Duration::from_secs(5))
            .connect_with(connect_opts)
            .await
            .map_err(|error| map_file_error(error, &path))?;
        Ok(Box::new(SqliteConnection { pool }))
    }
}

struct SqliteConnection {
    pool: Pool<Sqlite>,
}

#[async_trait]
impl Connection for SqliteConnection {
    async fn list_tables(&self) -> Result<Vec<TableInfo>, DriverError> {
        let rows = sqlx::query(
            "SELECT name FROM sqlite_master
             WHERE type = 'table' AND name NOT LIKE 'sqlite_%'
             ORDER BY name",
        )
        .fetch_all(&self.pool)
        .await
        .map_err(map_sqlx_error)?;
        Ok(rows
            .into_iter()
            .map(|r| TableInfo {
                schema: None,
                name: r.get::<String, _>(0),
            })
            .collect())
    }

    async fn fetch_columns(&self, _schema: Option<&str>, table: &str) -> Result<Vec<ColumnInfo>, DriverError> {
        // PRAGMA table_xinfo includes the `hidden` column which we use
        // to detect virtual / generated columns. Falls back to
        // table_info on older SQLite (< 3.37) — both have the same
        // first 6 columns: cid, name, type, notnull, dflt_value, pk.
        let pragma_sql = format!("PRAGMA table_xinfo({})", quote_ident(table));
        let rows = sqlx::query(AssertSqlSafe(pragma_sql))
            .fetch_all(&self.pool)
            .await
            .map_err(map_sqlx_error)?;

        // AUTOINCREMENT detection: `sqlite_sequence` is the canonical
        // signal. SQLite creates a row in that table for every table
        // declared with AUTOINCREMENT and updates it on each insert.
        // The query may fail (table doesn't exist when no AUTOINCREMENT
        // table has ever existed in the database); we treat any error
        // as "not autoincrement" rather than propagating.
        //
        // The previous implementation substring-matched the CREATE
        // TABLE DDL for "AUTOINCREMENT", which mis-flagged columns
        // whose names contained that token, comments mentioning the
        // keyword, or unrelated parts of the schema.
        let table_has_autoincrement =
            sqlx::query_scalar::<_, String>("SELECT name FROM sqlite_sequence WHERE name = ?")
                .bind(table)
                .fetch_optional(&self.pool)
                .await
                .ok()
                .flatten()
                .is_some();

        // Single-column PK detection: only a single-column INTEGER PK
        // is a rowid alias and auto-fills. Composite PKs (each member
        // reports `pk > 0`) never auto-increment, even if a member is
        // INTEGER.
        let pk_count = rows.iter().filter(|r| r.get::<i64, _>(5) > 0).count();
        let single_col_pk = pk_count == 1;

        Ok(rows
            .into_iter()
            .map(|r| {
                let name: String = r.get(1);
                let data_type: String = r.get(2);
                let primary_key = r.get::<i64, _>(5) > 0;
                let dflt: Option<String> = r.try_get::<Option<String>, _>(4).unwrap_or(None);
                let hidden: i64 = r.try_get::<i64, _>(6).unwrap_or(0);
                // hidden=2 → STORED generated; hidden=3 → VIRTUAL generated.
                let is_generated = hidden == 2 || hidden == 3;
                let is_int_type = data_type.eq_ignore_ascii_case("INTEGER");
                // INTEGER PRIMARY KEY (with or without AUTOINCREMENT)
                // is a rowid alias that auto-fills on insert when no
                // explicit default is set. The strict AUTOINCREMENT
                // form additionally guarantees monotonic ids via
                // sqlite_sequence; both behave the same to the inline-
                // insert UI.
                let is_auto_increment =
                    primary_key && is_int_type && single_col_pk && (table_has_autoincrement || dflt.is_none());
                let default = match dflt.map(normalize_default_value) {
                    Some(text) => ColumnDefault::Expression(SqlExpression::from_catalog_text(text)),
                    None => ColumnDefault::None,
                };
                ColumnInfo {
                    name,
                    column_type: column_type_of(&data_type),
                    nullable: r.get::<i64, _>(3) == 0,
                    primary_key,
                    is_auto_increment,
                    is_generated,
                    default,
                    // SQLite keeps no column descriptions. A comment in
                    // the CREATE TABLE text is discarded by the parser,
                    // so there is nothing to read back.
                    comment: None,
                }
            })
            .collect())
    }

    async fn fetch_rows(
        &self,
        _schema: Option<&str>,
        table: &str,
        offset: u64,
        limit: u64,
    ) -> Result<QueryResult, DriverError> {
        let sql = format!("SELECT * FROM {} LIMIT {limit} OFFSET {offset}", quote_ident(table));
        stream_into_result(&self.pool, &sql, limit as usize).await
    }

    async fn query(&self, sql: &str) -> Result<QueryResult, DriverError> {
        stream_into_result(&self.pool, sql, MAX_QUERY_ROWS).await
    }

    async fn query_params(&self, sql: &str, params: &[Value]) -> Result<QueryResult, DriverError> {
        let q = bind_sqlite_params(sqlx::query(AssertSqlSafe(sql)), params);
        let mut stream = q.fetch(&self.pool);
        let mut collected: Vec<SqliteRow> = Vec::new();
        let mut truncated = false;
        while let Some(row_result) = stream.next().await {
            let row = row_result.map_err(map_sqlx_error)?;
            if collected.len() >= MAX_QUERY_ROWS {
                truncated = true;
                break;
            }
            collected.push(row);
        }
        if collected.is_empty() {
            return Ok(QueryResult::empty().truncated(truncated));
        }
        let columns: Vec<ResultColumn> = collected[0]
            .columns()
            .iter()
            .map(|c| ResultColumn::new(c.name(), column_type_of(c.type_info().name())))
            .collect();
        let width = columns.len();
        let data: Vec<Vec<Value>> = collected
            .iter()
            .map(|r| (0..width).map(|i| extract_value(r, i)).collect())
            .collect();
        Ok(QueryResult::new(columns, data).truncated(truncated))
    }

    async fn execute(&self, sql: &str) -> Result<ExecResult, DriverError> {
        let res = sqlx::query(AssertSqlSafe(sql))
            .execute(&self.pool)
            .await
            .map_err(map_sqlx_error)?;
        Ok(ExecResult {
            rows_affected: res.rows_affected(),
        })
    }

    async fn execute_params(&self, sql: &str, params: &[Value]) -> Result<ExecResult, DriverError> {
        let q = bind_sqlite_params(sqlx::query(AssertSqlSafe(sql)), params);
        let res = q.execute(&self.pool).await.map_err(map_sqlx_error)?;
        Ok(ExecResult {
            rows_affected: res.rows_affected(),
        })
    }

    async fn execute_in_transaction(&self, statements: &[(String, Vec<Value>)]) -> Result<Vec<u64>, DriverError> {
        let mut tx = self.pool.begin().await.map_err(map_sqlx_error)?;
        let mut affected = Vec::with_capacity(statements.len());
        for (idx, (sql, params)) in statements.iter().enumerate() {
            let q = bind_sqlite_params(sqlx::query(AssertSqlSafe(sql.as_str())), params);
            match q.execute(&mut *tx).await {
                Ok(res) => affected.push(res.rows_affected()),
                Err(e) => {
                    let _ = tx.rollback().await;
                    return Err(DriverError::RolledBack {
                        statement_index: idx,
                        source: Box::new(map_sqlx_error(e)),
                    });
                }
            }
        }
        tx.commit().await.map_err(map_sqlx_error)?;
        Ok(affected)
    }

    async fn fetch_indexes(&self, _schema: Option<&str>, table: &str) -> Result<Vec<IndexInfo>, DriverError> {
        // SQLite catalog access is via PRAGMAs — they're scoped to the
        // current database file (no schema parameter needed). For each
        // entry from index_list we issue an index_info to get column
        // ordering. PK index doesn't always show up in index_list (a
        // bare INTEGER PRIMARY KEY uses the rowid alias, no real
        // index), so we synthesise one from table_info if missing.
        let list = sqlx::query(AssertSqlSafe(format!("PRAGMA index_list({})", quote_ident(table))))
            .fetch_all(&self.pool)
            .await
            .map_err(map_sqlx_error)?;
        let mut out: Vec<IndexInfo> = Vec::with_capacity(list.len());
        let mut saw_primary = false;
        for r in list {
            let name: String = r.try_get(1).map_err(map_sqlx_error)?;
            let unique: i64 = r.try_get(2).unwrap_or(0);
            let origin: String = r.try_get(3).unwrap_or_default();
            let primary = origin == "pk";
            if primary {
                saw_primary = true;
            }
            let info_rows = sqlx::query(AssertSqlSafe(format!("PRAGMA index_info({})", quote_ident(&name))))
                .fetch_all(&self.pool)
                .await
                .map_err(map_sqlx_error)?;
            let columns: Vec<String> = info_rows
                .into_iter()
                .map(|c| c.try_get::<String, _>(2).unwrap_or_default())
                .collect();
            out.push(IndexInfo {
                name,
                columns,
                unique: unique == 1,
                primary,
            });
        }
        if !saw_primary {
            // Synthesise the implicit PK index from PRAGMA table_info
            // so the UI can render PK columns even when SQLite chose
            // the rowid-alias path.
            let table_info = sqlx::query(AssertSqlSafe(format!("PRAGMA table_info({})", quote_ident(table))))
                .fetch_all(&self.pool)
                .await
                .map_err(map_sqlx_error)?;
            let pk_cols: Vec<String> = table_info
                .into_iter()
                .filter(|r| r.try_get::<i64, _>(5).unwrap_or(0) > 0)
                .map(|r| r.try_get::<String, _>(1).unwrap_or_default())
                .collect();
            if !pk_cols.is_empty() {
                out.push(IndexInfo {
                    name: "PRIMARY".into(),
                    columns: pk_cols,
                    unique: true,
                    primary: true,
                });
            }
        }
        Ok(out)
    }

    async fn fetch_foreign_keys(&self, _schema: Option<&str>, table: &str) -> Result<Vec<ForeignKeyInfo>, DriverError> {
        // PRAGMA foreign_key_list returns one row per (constraint, ordinal)
        // grouped by the synthetic `id` field. Constraint names aren't
        // stored by SQLite, so we synthesise "fk_{table}_{id}" — stable
        // across re-runs of the same schema. Group by id and build
        // ForeignKeyInfo.
        let rows = sqlx::query(AssertSqlSafe(format!(
            "PRAGMA foreign_key_list({})",
            quote_ident(table)
        )))
        .fetch_all(&self.pool)
        .await
        .map_err(map_sqlx_error)?;
        let mut by_id: std::collections::BTreeMap<i64, ForeignKeyInfo> = std::collections::BTreeMap::new();
        for r in rows {
            let id: i64 = r.try_get(0).unwrap_or(0);
            let ref_table: String = r.try_get(2).unwrap_or_default();
            let from_col: String = r.try_get(3).unwrap_or_default();
            let to_col: String = r.try_get(4).unwrap_or_default();
            let on_update: String = r.try_get(5).unwrap_or_default();
            let on_delete: String = r.try_get(6).unwrap_or_default();
            let entry = by_id.entry(id).or_insert_with(|| ForeignKeyInfo {
                name: format!("fk_{table}_{id}"),
                columns: Vec::new(),
                ref_schema: None,
                ref_table,
                ref_columns: Vec::new(),
                on_delete: Some(on_delete.clone()).filter(|s| !s.is_empty() && s != "NO ACTION"),
                on_update: Some(on_update.clone()).filter(|s| !s.is_empty() && s != "NO ACTION"),
            });
            entry.columns.push(from_col);
            entry.ref_columns.push(to_col);
        }
        Ok(by_id.into_values().collect())
    }

    async fn ping(&self) -> Result<(), DriverError> {
        sqlx::query("SELECT 1")
            .execute(&self.pool)
            .await
            .map_err(map_sqlx_error)?;
        Ok(())
    }

    async fn close(self: Box<Self>) -> Result<(), DriverError> {
        self.pool.close().await;
        Ok(())
    }
}

async fn stream_into_result(pool: &Pool<Sqlite>, sql: &str, limit: usize) -> Result<QueryResult, DriverError> {
    let mut stream = sqlx::query(AssertSqlSafe(sql)).fetch(pool);
    let mut collected: Vec<SqliteRow> = Vec::new();
    let mut truncated = false;
    while let Some(row_result) = stream.next().await {
        let row = row_result.map_err(map_sqlx_error)?;
        if collected.len() >= limit {
            truncated = true;
            break;
        }
        collected.push(row);
    }
    if collected.is_empty() {
        return Ok(QueryResult::empty().truncated(truncated));
    }
    let columns: Vec<ResultColumn> = collected[0]
        .columns()
        .iter()
        .map(|c| ResultColumn::new(c.name(), column_type_of(c.type_info().name())))
        .collect();
    let width = columns.len();
    let data: Vec<Vec<Value>> = collected
        .iter()
        .map(|r| (0..width).map(|i| extract_value(r, i)).collect())
        .collect();
    Ok(QueryResult::new(columns, data).truncated(truncated))
}

fn extract_value(row: &SqliteRow, idx: usize) -> Value {
    let declared = row.columns()[idx].type_info().name().to_ascii_uppercase();
    let storage = match row.try_get_raw(idx) {
        Ok(raw) => raw.type_info().name().to_ascii_uppercase(),
        Err(_) => return undecodable(&declared),
    };
    // SQLite keeps the storage class of the value, not of the column,
    // so an INTEGER column holding text reads as the text it holds.
    match storage.as_str() {
        "NULL" => Value::Null,
        "INTEGER" => decode(row, idx, &declared, |v: i64| {
            Some(match (declared.as_str(), v) {
                ("BOOLEAN", 0) => Value::Bool(false),
                ("BOOLEAN", 1) => Value::Bool(true),
                _ => Value::Int(v),
            })
        }),
        "REAL" => decode(row, idx, &declared, |v: f64| Some(Value::Float64(v))),
        "BLOB" => decode(row, idx, &declared, |v: Vec<u8>| Some(Value::Bytes(v))),
        _ => match declared.as_str() {
            "DATE" => temporal_cell(row, idx, &declared, |v: chrono::NaiveDate| {
                Value::Date(Temporal::Finite(v))
            }),
            "TIME" => temporal_cell(row, idx, &declared, |v: chrono::NaiveTime| {
                Value::Time(SqlTime::from_time_of_day(v))
            }),
            "DATETIME" | "TIMESTAMP" => temporal_cell(row, idx, &declared, |v: chrono::NaiveDateTime| {
                Value::Timestamp(Temporal::Finite(v))
            }),
            _ => text_cell(row, idx, &declared),
        },
    }
}

/// Read one cell, keeping three outcomes apart: a real NULL, a value
/// the driver read, and one it could not read. A type with no decoder
/// says so rather than reading as an empty cell the user would take
/// for a NULL.
fn decode<'r, T, F>(row: &'r SqliteRow, idx: usize, type_name: &str, into_value: F) -> Value
where
    T: sqlx::Decode<'r, Sqlite> + sqlx::Type<Sqlite>,
    F: FnOnce(T) -> Option<Value>,
{
    match row.try_get::<Option<T>, _>(idx) {
        Ok(Some(raw)) => into_value(raw).unwrap_or_else(|| undecodable(type_name)),
        Ok(None) => Value::Null,
        Err(_) => undecodable(type_name),
    }
}

/// SQLite stores a date as whatever text was written, so a value that
/// is not one keeps the text it holds.
fn temporal_cell<'r, T, F>(row: &'r SqliteRow, idx: usize, type_name: &str, into_value: F) -> Value
where
    T: sqlx::Decode<'r, Sqlite> + sqlx::Type<Sqlite>,
    F: FnOnce(T) -> Value,
{
    match row.try_get::<T, _>(idx) {
        Ok(value) => into_value(value),
        Err(_) => text_cell(row, idx, type_name),
    }
}

fn text_cell(row: &SqliteRow, idx: usize, type_name: &str) -> Value {
    decode(row, idx, type_name, |v: String| Some(Value::Text(v)))
}

/// A value the driver could not read, so the grid says so rather than
/// showing an empty cell that looks like a NULL.
fn undecodable(type_name: &str) -> Value {
    Value::Undecodable(Box::new(tablepro_core::value::UndecodedValue {
        type_name: type_name.to_owned(),
        reason: tablepro_core::value::UndecodableReason::UnsupportedType,
    }))
}

/// A column type from the name the catalogue gave, classified by the
/// shared rules. The engine's own spelling is kept for DDL.
fn column_type_of(type_name: &str) -> ColumnType {
    let kind = classify_type_name(type_name);
    ColumnType::new(
        SqlTypeExpr::from_catalog_text(type_name),
        kind,
        CatalogType::Named(SqlTypeExpr::from_catalog_text(type_name)),
        has_dynamic_storage(kind),
        ReadForm::Native,
    )
}

fn bind_sqlite_params<'q>(
    mut q: sqlx::query::Query<'q, Sqlite, sqlx::sqlite::SqliteArguments>,
    params: &'q [Value],
) -> sqlx::query::Query<'q, Sqlite, sqlx::sqlite::SqliteArguments> {
    for p in params {
        q = match p {
            Value::Null => q.bind(Option::<&str>::None),
            Value::Bool(b) => q.bind(*b),
            Value::Int(i) => q.bind(*i),
            // SQLite has no unsigned integer, so anything past i64
            // binds as text rather than wrapping into a negative.
            Value::UInt(i) => match i64::try_from(*i) {
                Ok(value) => q.bind(value),
                Err(_) => q.bind(i.to_string()),
            },
            Value::Float32(f) => q.bind(f64::from(*f)),
            Value::Float64(f) => q.bind(*f),
            Value::Text(s) => q.bind(s.clone()),
            Value::Bytes(b) => q.bind(b.clone()),
            Value::Date(Temporal::Finite(d)) => q.bind(*d),
            Value::Timestamp(Temporal::Finite(t)) => q.bind(*t),
            Value::Uuid(u) => q.bind(u.to_string()),
            Value::Json(j) => q.bind(j.as_str().to_owned()),
            // Everything else is stored as the text SQLite would have
            // written anyway, which is what its dynamic typing does.
            other => match tablepro_core::export::value_to_text(other) {
                Some(text) => q.bind(text),
                None => q.bind(Option::<&str>::None),
            },
        };
    }
    q
}

fn quote_ident(name: &str) -> String {
    format!("\"{}\"", name.replace('"', "\"\""))
}

/// Normalize the `default_value` text returned by `pragma_table_xinfo`.
/// SQLite stores string defaults with the surrounding apostrophes
/// (`'pending'` literal in the dflt_value column); other drivers return
/// the raw expression. Strip a single matched pair of outer single
/// quotes so the value reads as the user would type it. Numeric and
/// expression defaults (e.g. `CURRENT_TIMESTAMP`) are returned
/// unchanged.
fn normalize_default_value(raw: String) -> String {
    let bytes = raw.as_bytes();
    if bytes.len() >= 2 && bytes[0] == b'\'' && bytes[bytes.len() - 1] == b'\'' {
        // SQLite escapes embedded apostrophes by doubling them; collapse.
        let inner = &raw[1..raw.len() - 1];
        return inner.replace("''", "'");
    }
    raw
}

/// A failure while opening the database, where the file itself is
/// usually the answer.
fn map_file_error(err: sqlx::Error, path: &std::path::Path) -> DriverError {
    let sqlite = match &err {
        sqlx::Error::Database(error) => error.try_downcast_ref::<sqlx::sqlite::SqliteError>(),
        _ => None,
    };
    match sqlite.map(primary_code) {
        Some(SQLITE_CANTOPEN) => DriverError::FileAccessDenied {
            path: path.to_path_buf(),
        },
        Some(SQLITE_NOTADB) => DriverError::NotADatabase {
            path: path.to_path_buf(),
        },
        _ => map_sqlx_error(err),
    }
}

fn map_sqlx_error(err: sqlx::Error) -> DriverError {
    match err {
        sqlx::Error::Database(error) => match error.try_downcast_ref::<sqlx::sqlite::SqliteError>() {
            Some(sqlite) => server_error(sqlite),
            None => DriverError::server(error.message().to_owned()),
        },
        sqlx::Error::Io(_) => DriverError::ConnectionLost {
            during: LossPhase::Statement,
        },
        // Every connection in the pool is held by a longer write, so
        // the database is busy rather than gone.
        sqlx::Error::PoolTimedOut => DriverError::Busy,
        sqlx::Error::PoolClosed | sqlx::Error::WorkerCrashed => DriverError::ConnectionLost {
            during: LossPhase::Idle,
        },
        sqlx::Error::ColumnDecode { index, source } => DriverError::Decode {
            column: index,
            detail: source.to_string(),
        },
        other => DriverError::Protocol(other.to_string()),
    }
}

/// SQLite reports an extended result code whose low byte is the
/// primary one, which is what these branches turn on.
fn server_error(sqlite: &sqlx::sqlite::SqliteError) -> DriverError {
    let diagnostics = diagnostics_of(sqlite);
    match primary_code(sqlite) {
        SQLITE_BUSY | SQLITE_LOCKED => DriverError::Busy,
        SQLITE_READONLY => DriverError::ReadOnly(ReadOnlyRefusal::server(diagnostics)),
        SQLITE_INTERRUPT => DriverError::Cancelled,
        _ => DriverError::reported(diagnostics),
    }
}

fn diagnostics_of(sqlite: &sqlx::sqlite::SqliteError) -> ServerDiagnostics {
    use sqlx::error::DatabaseError;

    let extended = extended_code(sqlite);
    ServerDiagnostics::new(
        Some(ServerCode::Sqlite {
            primary: extended & 0xff,
            extended,
        }),
        sqlite.message().to_owned(),
    )
}

fn extended_code(sqlite: &sqlx::sqlite::SqliteError) -> i32 {
    use sqlx::error::DatabaseError;

    sqlite
        .code()
        .and_then(|code| code.parse::<i32>().ok())
        .unwrap_or(SQLITE_ERROR)
}

fn primary_code(sqlite: &sqlx::sqlite::SqliteError) -> i32 {
    extended_code(sqlite) & 0xff
}

const SQLITE_ERROR: i32 = 1;
const SQLITE_BUSY: i32 = 5;
const SQLITE_LOCKED: i32 = 6;
const SQLITE_READONLY: i32 = 8;
const SQLITE_INTERRUPT: i32 = 9;
const SQLITE_CANTOPEN: i32 = 14;
const SQLITE_NOTADB: i32 = 26;

#[cfg(test)]
mod tests {
    use super::*;
    use tempfile::TempDir;

    fn opts_for(path: &str) -> ConnectOptions {
        ConnectOptions {
            database: path.to_string(),
            ..Default::default()
        }
    }

    #[tokio::test]
    async fn driver_metadata() {
        let d = SqliteDriver;
        assert_eq!(d.id(), "sqlite");
        assert_eq!(d.display_name(), "SQLite");
    }

    #[tokio::test]
    async fn connect_create_and_list_tables() {
        let dir = TempDir::new().unwrap();
        let path = dir.path().join("test.db");
        let driver = SqliteDriver;
        let conn = driver.connect(opts_for(path.to_str().unwrap())).await.unwrap();
        conn.execute("CREATE TABLE foo (id INTEGER PRIMARY KEY, name TEXT)")
            .await
            .unwrap();
        conn.execute("INSERT INTO foo (name) VALUES ('a'), ('b'), ('c')")
            .await
            .unwrap();
        let tables = conn.list_tables().await.unwrap();
        assert_eq!(tables.len(), 1);
        assert_eq!(tables[0].name, "foo");
        let cols = conn.fetch_columns(None, "foo").await.unwrap();
        assert_eq!(cols.len(), 2);
        assert_eq!(cols[0].name, "id");
        assert!(cols[0].primary_key);
        let result = conn.fetch_rows(None, "foo", 0, 100).await.unwrap();
        assert_eq!(result.columns.len(), 2);
        assert_eq!(result.rows.len(), 3);
    }

    #[tokio::test]
    async fn fetch_rows_paginates() {
        let dir = TempDir::new().unwrap();
        let path = dir.path().join("page.db");
        let driver = SqliteDriver;
        let conn = driver.connect(opts_for(path.to_str().unwrap())).await.unwrap();
        conn.execute("CREATE TABLE n (i INTEGER)").await.unwrap();
        for i in 1..=10 {
            conn.execute(&format!("INSERT INTO n VALUES ({i})")).await.unwrap();
        }
        let page = conn.fetch_rows(None, "n", 5, 3).await.unwrap();
        assert_eq!(page.rows.len(), 3);
    }

    #[test]
    fn quote_ident_doubles_embedded_quotes() {
        assert_eq!(quote_ident("users"), "\"users\"");
        assert_eq!(quote_ident("My Table"), "\"My Table\"");
        assert_eq!(
            quote_ident("evil\"; DROP TABLE x; --"),
            "\"evil\"\"; DROP TABLE x; --\""
        );
    }

    #[tokio::test]
    async fn fetch_rows_handles_table_with_embedded_quote() {
        let dir = TempDir::new().unwrap();
        let path = dir.path().join("hostile.db");
        let driver = SqliteDriver;
        let conn = driver.connect(opts_for(path.to_str().unwrap())).await.unwrap();
        conn.execute("CREATE TABLE \"weird\"\"name\" (i INTEGER)")
            .await
            .unwrap();
        conn.execute("INSERT INTO \"weird\"\"name\" VALUES (1), (2)")
            .await
            .unwrap();
        let result = conn.fetch_rows(None, "weird\"name", 0, 100).await.unwrap();
        assert_eq!(result.rows.len(), 2);
    }

    #[tokio::test]
    async fn autoincrement_detected_via_sqlite_sequence() {
        let dir = TempDir::new().unwrap();
        let path = dir.path().join("ai.db");
        let driver = SqliteDriver;
        let conn = driver.connect(opts_for(path.to_str().unwrap())).await.unwrap();
        conn.execute("CREATE TABLE t (id INTEGER PRIMARY KEY AUTOINCREMENT, name TEXT)")
            .await
            .unwrap();
        // Insert at least one row so sqlite_sequence has an entry.
        conn.execute("INSERT INTO t (name) VALUES ('a')").await.unwrap();
        let cols = conn.fetch_columns(None, "t").await.unwrap();
        assert!(cols[0].is_auto_increment, "AUTOINCREMENT id should be flagged");
        assert!(!cols[1].is_auto_increment, "name column should not be flagged");
    }

    #[tokio::test]
    async fn integer_primary_key_no_autoincrement_is_rowid_alias() {
        // INTEGER PRIMARY KEY without AUTOINCREMENT is still a rowid
        // alias and auto-fills on insert. Should be flagged.
        let dir = TempDir::new().unwrap();
        let path = dir.path().join("rowid.db");
        let driver = SqliteDriver;
        let conn = driver.connect(opts_for(path.to_str().unwrap())).await.unwrap();
        conn.execute("CREATE TABLE t (id INTEGER PRIMARY KEY, name TEXT)")
            .await
            .unwrap();
        let cols = conn.fetch_columns(None, "t").await.unwrap();
        assert!(cols[0].is_auto_increment);
    }

    #[tokio::test]
    async fn integer_primary_key_with_default_is_not_auto_increment() {
        let dir = TempDir::new().unwrap();
        let path = dir.path().join("def.db");
        let driver = SqliteDriver;
        let conn = driver.connect(opts_for(path.to_str().unwrap())).await.unwrap();
        conn.execute("CREATE TABLE t (id INTEGER PRIMARY KEY DEFAULT 0, name TEXT)")
            .await
            .unwrap();
        let cols = conn.fetch_columns(None, "t").await.unwrap();
        assert!(!cols[0].is_auto_increment);
    }

    #[tokio::test]
    async fn composite_primary_key_no_auto_increment() {
        let dir = TempDir::new().unwrap();
        let path = dir.path().join("composite.db");
        let driver = SqliteDriver;
        let conn = driver.connect(opts_for(path.to_str().unwrap())).await.unwrap();
        conn.execute("CREATE TABLE t (a INTEGER, b TEXT, PRIMARY KEY(a, b))")
            .await
            .unwrap();
        let cols = conn.fetch_columns(None, "t").await.unwrap();
        // Both members are part of the PK but neither auto-increments.
        assert!(!cols[0].is_auto_increment);
        assert!(!cols[1].is_auto_increment);
    }

    #[tokio::test]
    async fn column_named_autoincrement_substring_is_not_flagged() {
        // Pre-fix bug: ddl_upper.contains("AUTOINCREMENT") would match
        // a column named MYAUTOINCREMENT. Verify the canonical
        // sqlite_sequence path doesn't fall for this.
        let dir = TempDir::new().unwrap();
        let path = dir.path().join("substr.db");
        let driver = SqliteDriver;
        let conn = driver.connect(opts_for(path.to_str().unwrap())).await.unwrap();
        conn.execute("CREATE TABLE t (id INTEGER PRIMARY KEY, autoincrementflag INTEGER)")
            .await
            .unwrap();
        let cols = conn.fetch_columns(None, "t").await.unwrap();
        assert!(cols[0].is_auto_increment, "id is INTEGER PRIMARY KEY (rowid alias)");
        assert!(!cols[1].is_auto_increment, "non-PK INTEGER must not be flagged");
    }

    #[test]
    fn normalize_default_value_strips_outer_quotes() {
        assert_eq!(normalize_default_value("'pending'".into()), "pending");
        assert_eq!(normalize_default_value("'it''s'".into()), "it's");
        assert_eq!(normalize_default_value("0".into()), "0");
        assert_eq!(normalize_default_value("CURRENT_TIMESTAMP".into()), "CURRENT_TIMESTAMP");
        assert_eq!(normalize_default_value("'unbalanced".into()), "'unbalanced");
    }
}
