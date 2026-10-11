#[cfg(target_os = "linux")]
use std::os::{fd::AsRawFd, unix::fs::MetadataExt};
use std::{
    fs::File,
    sync::{Arc, Mutex},
};

use async_trait::async_trait;
use duckdb::{
    AccessMode, Config, Connection as DuckConnection, core::LogicalTypeId, params_from_iter, types::ValueRef,
};

use tablepro_core::{
    ColumnInfo, ConnectOptions, Connection, DatabaseDriver, DriverError, DriverMaturity, ExecResult, MAX_QUERY_ROWS,
    QueryResult, QueryResultBudget, TableInfo, Value,
};
use tempfile::TempDir;

mod temporal;

pub struct DuckdbDriver;

#[async_trait]
impl DatabaseDriver for DuckdbDriver {
    fn id(&self) -> &'static str {
        "duckdb"
    }

    fn display_name(&self) -> &'static str {
        "DuckDB"
    }

    fn maturity(&self) -> DriverMaturity {
        DriverMaturity::Experimental
    }

    fn default_port(&self) -> u16 {
        0
    }

    fn default_database(&self) -> &'static str {
        ""
    }

    fn default_username(&self) -> &'static str {
        ""
    }

    fn is_file_based(&self) -> bool {
        true
    }

    fn ddl_is_transactional(&self) -> bool {
        true
    }

    async fn connect(&self, opts: ConnectOptions) -> Result<Box<dyn Connection>, DriverError> {
        let path = opts.database.clone();
        let read_only = opts.read_only;
        let (conn, selected_file) = tokio::task::spawn_blocking(move || open_path_with_access(&path, read_only))
            .await
            .map_err(|e| DriverError::Internal(format!("duckdb connect join: {e}")))??;
        Ok(Box::new(DuckdbConnection {
            session: Arc::new(DuckdbSession {
                conn: Mutex::new(conn),
                _selected_file: selected_file,
            }),
        }))
    }
}

fn open_path_with_access(
    path: &str,
    read_only: bool,
) -> Result<(DuckConnection, Option<SelectedFlatFile>), DriverError> {
    if !read_only {
        return open_path(path).map(|conn| (conn, None));
    }
    if path.is_empty() || path == ":memory:" {
        return Err(DriverError::Unsupported(
            "read-only DuckDB requires a database file or a selected flat file".into(),
        ));
    }
    if let Some(reader_fn) = flat_file_reader_fn(path) {
        let (conn, selected_file) = open_read_only_flat_file(path, reader_fn)?;
        return Ok((conn, Some(selected_file)));
    }

    let config = Config::default()
        .access_mode(AccessMode::ReadOnly)
        .map_err(map_duck_error)?
        .enable_external_access(false)
        .map_err(map_duck_error)?;
    let conn = DuckConnection::open_with_flags(path, config).map_err(map_duck_error)?;
    conn.execute_batch("SET lock_configuration = true;")
        .map_err(map_duck_error)?;
    Ok((conn, None))
}

#[cfg(target_os = "linux")]
fn open_read_only_flat_file(path: &str, reader_fn: &str) -> Result<(DuckConnection, SelectedFlatFile), DriverError> {
    let canonical = std::fs::canonicalize(path).map_err(map_file_error)?;
    let before_open = std::fs::metadata(&canonical).map_err(map_file_error)?;
    if !before_open.is_file() {
        return Err(DriverError::PolicyDenied(
            "the selected DuckDB input must be a regular file".into(),
        ));
    }
    let file = open_selected_file(&canonical, &before_open)?;
    let opened = file.metadata().map_err(map_file_error)?;
    let after_open = std::fs::metadata(&canonical).map_err(map_file_error)?;
    if !opened.is_file() || !same_file_identity(&before_open, &opened) || !same_file_identity(&opened, &after_open) {
        return Err(DriverError::PolicyDenied(
            "the selected DuckDB input changed during read-only connection setup".into(),
        ));
    }

    let parent = canonical
        .parent()
        .ok_or_else(|| DriverError::Unsupported("selected DuckDB input has no parent directory".into()))?;
    let private_dir = private_alias_directory(parent, opened.dev())?;
    let pinned_path = private_dir.path().join("selected-input");
    std::fs::hard_link(&canonical, &pinned_path).map_err(map_file_error)?;
    let alias_metadata = std::fs::metadata(&pinned_path).map_err(map_file_error)?;
    if !same_file_identity(&opened, &alias_metadata) {
        return Err(DriverError::PolicyDenied(
            "the selected DuckDB input changed while it was being pinned".into(),
        ));
    }
    let stable_path = pinned_path.to_string_lossy();
    let conn = DuckConnection::open_in_memory().map_err(map_duck_error)?;
    conn.execute_batch(&format!(
        "SET allowed_paths = ['{}']; \
         SET enable_external_access = false; \
         CREATE VIEW {} AS SELECT * FROM {}('{}'); \
         SET lock_configuration = true;",
        escape_duckdb_literal(&stable_path),
        quote_duckdb_ident(&derive_view_name(path)),
        reader_fn,
        escape_duckdb_literal(&stable_path)
    ))
    .map_err(map_duck_error)?;
    Ok((
        conn,
        SelectedFlatFile {
            _file: file,
            _private_dir: private_dir,
        },
    ))
}

#[cfg(target_os = "linux")]
fn private_alias_directory(parent: &std::path::Path, device: u64) -> Result<TempDir, DriverError> {
    let mut candidates = vec![parent.to_path_buf()];
    candidates.extend(
        ["XDG_CACHE_HOME", "HOME"]
            .into_iter()
            .filter_map(std::env::var_os)
            .map(std::path::PathBuf::from),
    );
    candidates.push(std::env::temp_dir());

    let mut last_error = None;
    for candidate in candidates {
        let Ok(metadata) = std::fs::metadata(&candidate) else {
            continue;
        };
        if !metadata.is_dir() || metadata.dev() != device {
            continue;
        }
        match tempfile::Builder::new().prefix(".bookie-duckdb-").tempdir_in(candidate) {
            Ok(directory) => return Ok(directory),
            Err(error) => last_error = Some(error),
        }
    }
    match last_error {
        Some(error) => Err(map_file_error(error)),
        None => Err(DriverError::Unsupported(
            "no writable private directory shares the selected DuckDB file system".into(),
        )),
    }
}

#[cfg(target_os = "linux")]
fn open_selected_file(path: &std::path::Path, expected: &std::fs::Metadata) -> Result<File, DriverError> {
    use std::os::unix::fs::OpenOptionsExt;

    let path_fd = std::fs::OpenOptions::new()
        .read(true)
        .custom_flags(libc::O_PATH | libc::O_NOFOLLOW | libc::O_CLOEXEC)
        .open(path)
        .map_err(map_file_error)?;
    let pinned = path_fd.metadata().map_err(map_file_error)?;
    if !pinned.is_file() || !same_file_identity(expected, &pinned) {
        return Err(DriverError::PolicyDenied(
            "the selected DuckDB input changed during read-only connection setup".into(),
        ));
    }

    let proc_fd_dir = std::path::Path::new("/proc/self/fd");
    if !proc_fd_dir.is_dir() {
        return Err(DriverError::Unsupported(
            "read-only DuckDB flat-file access requires Linux procfs file descriptors".into(),
        ));
    }
    let pinned_path = proc_fd_dir.join(path_fd.as_raw_fd().to_string());
    let file = std::fs::OpenOptions::new()
        .read(true)
        .custom_flags(libc::O_NONBLOCK | libc::O_CLOEXEC)
        .open(pinned_path)
        .map_err(map_file_error)?;
    let opened = file.metadata().map_err(map_file_error)?;
    if !opened.is_file() || !same_file_identity(&pinned, &opened) {
        return Err(DriverError::PolicyDenied(
            "the selected DuckDB input changed during read-only connection setup".into(),
        ));
    }
    Ok(file)
}

#[cfg(not(target_os = "linux"))]
fn open_read_only_flat_file(_path: &str, _reader_fn: &str) -> Result<(DuckConnection, SelectedFlatFile), DriverError> {
    Err(DriverError::Unsupported(
        "read-only DuckDB flat-file access is supported only on Linux".into(),
    ))
}

#[cfg(target_os = "linux")]
fn same_file_identity(left: &std::fs::Metadata, right: &std::fs::Metadata) -> bool {
    left.dev() == right.dev() && left.ino() == right.ino()
}

fn map_file_error(error: std::io::Error) -> DriverError {
    DriverError::Internal(format!("DuckDB selected file setup failed: {error}"))
}

/// A `.duckdb`/`.db` file opens directly. A flat data file (Parquet,
/// CSV, TSV, JSON) isn't a DuckDB database at all -- open an in-memory
/// database instead and expose the file as a view through DuckDB's own
/// file-reading functions, so the rest of the driver (which only knows
/// how to query DuckDB tables/views) needs no special case.
fn open_path(path: &str) -> Result<DuckConnection, DriverError> {
    if path.is_empty() || path == ":memory:" {
        return DuckConnection::open_in_memory().map_err(map_duck_error);
    }
    let Some(reader_fn) = flat_file_reader_fn(path) else {
        return DuckConnection::open(path).map_err(map_duck_error);
    };
    let conn = DuckConnection::open_in_memory().map_err(map_duck_error)?;
    let sql = format!(
        "CREATE VIEW {} AS SELECT * FROM {}('{}')",
        quote_duckdb_ident(&derive_view_name(path)),
        reader_fn,
        escape_duckdb_literal(path)
    );
    conn.execute(&sql, []).map_err(map_duck_error)?;
    Ok(conn)
}

fn flat_file_reader_fn(path: &str) -> Option<&'static str> {
    let lower = path.to_ascii_lowercase();
    if lower.ends_with(".parquet") {
        Some("read_parquet")
    } else if lower.ends_with(".csv") || lower.ends_with(".tsv") {
        Some("read_csv_auto")
    } else if lower.ends_with(".json") {
        Some("read_json_auto")
    } else {
        None
    }
}

/// The file's stem, sanitized into a safe view name -- falls back to
/// "data" for a stem that sanitizes away to nothing (an all-symbol
/// filename, or none at all).
fn derive_view_name(path: &str) -> String {
    std::path::Path::new(path)
        .file_stem()
        .and_then(std::ffi::OsStr::to_str)
        .map(sanitize_ident)
        .filter(|s| !s.is_empty())
        .unwrap_or_else(|| "data".to_string())
}

fn sanitize_ident(name: &str) -> String {
    let mut out: String = name
        .chars()
        .map(|c| if c.is_ascii_alphanumeric() || c == '_' { c } else { '_' })
        .collect();
    if out.chars().next().is_some_and(|c| c.is_ascii_digit()) {
        out.insert(0, '_');
    }
    out
}

fn quote_duckdb_ident(name: &str) -> String {
    format!("\"{}\"", name.replace('"', "\"\""))
}

fn escape_duckdb_literal(value: &str) -> String {
    value.replace('\'', "''")
}

struct DuckdbConnection {
    session: Arc<DuckdbSession>,
}

struct DuckdbSession {
    conn: Mutex<DuckConnection>,
    _selected_file: Option<SelectedFlatFile>,
}

struct SelectedFlatFile {
    _file: File,
    _private_dir: TempDir,
}

#[async_trait]
impl Connection for DuckdbConnection {
    async fn list_tables(&self) -> Result<Vec<TableInfo>, DriverError> {
        let conn = Arc::clone(&self.session);
        blocking(move || {
            let guard = conn
                .conn
                .lock()
                .map_err(|_| DriverError::Internal("duckdb lock poisoned".into()))?;
            let mut stmt = guard
                .prepare(
                    "SELECT table_schema, table_name FROM information_schema.tables \
                     WHERE table_schema NOT IN ('information_schema', 'pg_catalog') \
                     AND table_type = 'BASE TABLE' \
                     ORDER BY table_schema, table_name",
                )
                .map_err(map_duck_error)?;
            let rows = stmt
                .query_map([], |row| {
                    Ok(TableInfo {
                        schema: row.get::<_, Option<String>>(0)?,
                        name: row.get::<_, String>(1)?,
                    })
                })
                .map_err(map_duck_error)?;
            let mut out = Vec::new();
            for r in rows {
                out.push(r.map_err(map_duck_error)?);
            }
            Ok(out)
        })
        .await
    }

    async fn fetch_columns(&self, schema: Option<&str>, table: &str) -> Result<Vec<ColumnInfo>, DriverError> {
        let conn = Arc::clone(&self.session);
        let schema = schema.map(str::to_string);
        let table = table.to_string();
        blocking(move || {
            let guard = conn
                .conn
                .lock()
                .map_err(|_| DriverError::Internal("duckdb lock poisoned".into()))?;
            let (sql, binds) = match schema {
                Some(schema) => (
                    "SELECT c.column_name, c.data_type, c.is_nullable, c.column_default, \
                            EXISTS (SELECT 1 FROM duckdb_constraints() con \
                                    WHERE con.schema_name = c.table_schema \
                                      AND con.table_name = c.table_name \
                                      AND con.constraint_type = 'PRIMARY KEY' \
                                      AND list_contains(con.constraint_column_names, c.column_name)) \
                     FROM information_schema.columns c \
                     WHERE c.table_schema = ? AND c.table_name = ? \
                     ORDER BY c.ordinal_position",
                    vec![schema, table],
                ),
                None => (
                    "SELECT c.column_name, c.data_type, c.is_nullable, c.column_default, \
                            EXISTS (SELECT 1 FROM duckdb_constraints() con \
                                    WHERE con.schema_name = c.table_schema \
                                      AND con.table_name = c.table_name \
                                      AND con.constraint_type = 'PRIMARY KEY' \
                                      AND list_contains(con.constraint_column_names, c.column_name)) \
                     FROM information_schema.columns c \
                     WHERE c.table_name = ? \
                     ORDER BY c.ordinal_position",
                    vec![table],
                ),
            };
            let mut stmt = guard.prepare(sql).map_err(map_duck_error)?;
            let rows = stmt
                .query_map(params_from_iter(binds.iter()), |row| {
                    let nullable: String = row.get(2)?;
                    Ok(ColumnInfo {
                        name: row.get(0)?,
                        data_type: row.get(1)?,
                        nullable: nullable.eq_ignore_ascii_case("YES"),
                        primary_key: row.get(4)?,
                        is_auto_increment: false,
                        default_value: row.get(3)?,
                        is_generated: false,
                        comment: None,
                        collation: None,
                        enum_type: None,
                        domain_type: None,
                    })
                })
                .map_err(map_duck_error)?;
            let mut out = Vec::new();
            for r in rows {
                out.push(r.map_err(map_duck_error)?);
            }
            Ok(out)
        })
        .await
    }

    async fn fetch_rows(
        &self,
        schema: Option<&str>,
        table: &str,
        offset: u64,
        limit: u64,
    ) -> Result<QueryResult, DriverError> {
        let sql = format!(
            "SELECT * FROM {} LIMIT {limit} OFFSET {offset}",
            qualified(schema, table)
        );
        self.query(&sql).await
    }

    async fn query(&self, sql: &str) -> Result<QueryResult, DriverError> {
        let conn = Arc::clone(&self.session);
        let sql = sql.to_string();
        blocking(move || run_query(&conn, &sql, &[], MAX_QUERY_ROWS)).await
    }

    async fn query_params(&self, sql: &str, params: &[Value]) -> Result<QueryResult, DriverError> {
        let conn = Arc::clone(&self.session);
        let sql = sql.to_owned();
        let params = params.to_vec();
        blocking(move || run_query(&conn, &sql, &params, MAX_QUERY_ROWS)).await
    }

    async fn execute(&self, sql: &str) -> Result<ExecResult, DriverError> {
        let conn = Arc::clone(&self.session);
        let sql = sql.to_string();
        blocking(move || {
            let guard = conn
                .conn
                .lock()
                .map_err(|_| DriverError::Internal("duckdb lock poisoned".into()))?;
            let rows_affected = guard.execute(&sql, []).map_err(map_duck_error)? as u64;
            Ok(ExecResult { rows_affected })
        })
        .await
    }

    async fn execute_params(&self, sql: &str, params: &[Value]) -> Result<ExecResult, DriverError> {
        if params.is_empty() {
            return self.execute(sql).await;
        }
        let conn = Arc::clone(&self.session);
        let sql = sql.to_string();
        let params = params.to_vec();
        blocking(move || {
            let guard = conn
                .conn
                .lock()
                .map_err(|_| DriverError::Internal("duckdb lock poisoned".into()))?;
            let bind = values_to_duck_params(&params)?;
            let rows_affected = guard
                .execute(&sql, params_from_iter(bind.iter()))
                .map_err(map_duck_error)? as u64;
            Ok(ExecResult { rows_affected })
        })
        .await
    }

    async fn execute_in_transaction(&self, statements: &[(String, Vec<Value>)]) -> Result<Vec<u64>, DriverError> {
        let conn = Arc::clone(&self.session);
        let statements = statements.to_vec();
        blocking(move || {
            let guard = conn
                .conn
                .lock()
                .map_err(|_| DriverError::Internal("duckdb lock poisoned".into()))?;
            guard.execute_batch("BEGIN").map_err(map_duck_error)?;
            let mut affected = Vec::with_capacity(statements.len());
            for (idx, (sql, params)) in statements.iter().enumerate() {
                let result = if params.is_empty() {
                    guard.execute(sql, [])
                } else {
                    let bind = match values_to_duck_params(params) {
                        Ok(bind) => bind,
                        Err(error) => {
                            let _ = guard.execute_batch("ROLLBACK");
                            return Err(DriverError::Transaction {
                                statement_index: idx,
                                source: Box::new(error),
                            });
                        }
                    };
                    guard.execute(sql, params_from_iter(bind.iter()))
                };
                match result {
                    Ok(n) => affected.push(n as u64),
                    Err(e) => {
                        let _ = guard.execute_batch("ROLLBACK");
                        return Err(DriverError::Transaction {
                            statement_index: idx,
                            source: Box::new(map_duck_error(e)),
                        });
                    }
                }
            }
            guard.execute_batch("COMMIT").map_err(map_duck_error)?;
            Ok(affected)
        })
        .await
    }

    async fn ping(&self) -> Result<(), DriverError> {
        self.execute("SELECT 1").await.map(|_| ())
    }

    async fn server_version(&self) -> Result<Option<String>, DriverError> {
        let result = self.query("SELECT version()").await?;
        let version = result.rows.first().and_then(|r| r.first()).and_then(|v| match v {
            Value::Text(s) => Some(s.clone()),
            _ => None,
        });
        Ok(version.map(|v| format!("DuckDB {v}")))
    }

    async fn close(self: Box<Self>) -> Result<(), DriverError> {
        Ok(())
    }
}

fn run_query(conn: &Arc<DuckdbSession>, sql: &str, params: &[Value], limit: usize) -> Result<QueryResult, DriverError> {
    let guard = conn
        .conn
        .lock()
        .map_err(|_| DriverError::Internal("duckdb lock poisoned".into()))?;
    let mut stmt = guard.prepare(sql).map_err(map_duck_error)?;
    let bind = values_to_duck_params(params)?;
    let mut rows = if params.is_empty() {
        stmt.query([])
    } else {
        stmt.query(params_from_iter(bind.iter()))
    }
    .map_err(map_duck_error)?;

    // DuckDB requires the statement to be stepped before column metadata
    // is available. Collect all values first (capped), then read names.
    let mut raw_rows: Vec<Vec<Value>> = Vec::new();
    let mut budget = QueryResultBudget::default();
    let mut truncated = false;
    let mut column_count = 0usize;
    let mut zoned_columns = Vec::new();
    let mut uuid_columns = Vec::new();
    while let Some(row) = rows.next().map_err(map_duck_error)? {
        if column_count == 0 {
            column_count = row.as_ref().column_count();
            uuid_columns = (0..column_count)
                .map(|i| row.as_ref().column_logical_type(i).id() == LogicalTypeId::Uuid)
                .collect();
            zoned_columns = (0..column_count)
                .map(|i| {
                    matches!(
                        row.as_ref().column_type(i),
                        duckdb::arrow::datatypes::DataType::Timestamp(_, Some(_))
                    )
                })
                .collect();
        }
        if raw_rows.len() >= limit {
            truncated = true;
            break;
        }
        let values = zoned_columns
            .iter()
            .zip(&uuid_columns)
            .enumerate()
            .map(
                |(i, (zoned, uuid))| match duck_value_ref_to_value(row.get_ref_unwrap(i), *uuid) {
                    Value::DateTime(timestamp) if *zoned => Value::TimestampTz(timestamp.and_utc()),
                    Value::Text(timestamp) if *zoned && !matches!(timestamp.as_str(), "infinity" | "-infinity") => {
                        Value::Text(format!("{timestamp}+00"))
                    }
                    value => value,
                },
            )
            .collect::<Vec<_>>();
        if !budget.admit(&values) {
            truncated = true;
            break;
        }
        raw_rows.push(values);
    }
    if column_count == 0
        && let Some(stmt_ref) = rows.as_ref()
    {
        column_count = stmt_ref.column_count();
    }
    let columns: Vec<ColumnInfo> = if let Some(stmt_ref) = rows.as_ref() {
        (0..column_count)
            .map(|i| ColumnInfo {
                name: stmt_ref
                    .column_name(i)
                    .map(|s| s.to_string())
                    .unwrap_or_else(|_| format!("col{i}")),
                data_type: if stmt_ref.column_logical_type(i).id() == LogicalTypeId::Uuid {
                    "UUID".into()
                } else {
                    format!("{:?}", stmt_ref.column_type(i))
                },
                nullable: true,
                primary_key: false,
                is_auto_increment: false,
                default_value: None,
                is_generated: false,
                comment: None,
                collation: None,
                enum_type: None,
                domain_type: None,
            })
            .collect()
    } else {
        (0..column_count)
            .map(|i| ColumnInfo {
                name: format!("col{i}"),
                data_type: "UNKNOWN".into(),
                nullable: true,
                primary_key: false,
                is_auto_increment: false,
                default_value: None,
                is_generated: false,
                comment: None,
                collation: None,
                enum_type: None,
                domain_type: None,
            })
            .collect()
    };

    Ok(QueryResult {
        columns,
        rows: raw_rows,
        truncated,
    })
}

fn duck_value_ref_to_value(v: ValueRef<'_>, uuid_column: bool) -> Value {
    if uuid_column {
        return duck_uuid_ref_to_value(v);
    }
    match v {
        ValueRef::Null => Value::Null,
        ValueRef::Boolean(b) => Value::Bool(b),
        ValueRef::TinyInt(i) => Value::Int(i as i64),
        ValueRef::SmallInt(i) => Value::Int(i as i64),
        ValueRef::Int(i) => Value::Int(i as i64),
        ValueRef::BigInt(i) => Value::Int(i),
        ValueRef::HugeInt(i) => Value::Text(i.to_string()),
        ValueRef::UHugeInt(i) => Value::Text(i.to_string()),
        ValueRef::UTinyInt(i) => Value::Int(i as i64),
        ValueRef::USmallInt(i) => Value::Int(i as i64),
        ValueRef::UInt(i) => Value::Int(i as i64),
        ValueRef::UBigInt(i) => {
            if i <= i64::MAX as u64 {
                Value::Int(i as i64)
            } else {
                Value::Text(i.to_string())
            }
        }
        ValueRef::Float(f) => Value::Float(f as f64),
        ValueRef::Double(f) => Value::Float(f),
        ValueRef::Decimal(d) => rust_decimal_or_text(d),
        ValueRef::Text(t) => match std::str::from_utf8(t) {
            Ok(text) => Value::Text(text.to_owned()),
            Err(_) => Value::Bytes(t.to_vec()),
        },
        ValueRef::Blob(b) | ValueRef::Geometry(b) => Value::Bytes(b.to_vec()),
        ValueRef::Date32(d) => temporal::date(d),
        ValueRef::Time64(unit, t) => temporal::time(unit, t),
        ValueRef::Timestamp(unit, t) => temporal::timestamp(unit, t),
        ValueRef::Interval { months, days, nanos } if nanos % 1_000 == 0 => {
            let micros = nanos / 1_000;
            let month_unit = if months.unsigned_abs() == 1 { "month" } else { "months" };
            let day_unit = if days.unsigned_abs() == 1 { "day" } else { "days" };
            let microsecond_unit = if micros.unsigned_abs() == 1 {
                "microsecond"
            } else {
                "microseconds"
            };
            Value::Text(format!(
                "{months} {month_unit} {days} {day_unit} {micros} {microsecond_unit}"
            ))
        }
        ValueRef::Interval { .. } => Value::Undecodable("INTERVAL with sub-microsecond precision".into()),
        ValueRef::Enum(..) => v
            .as_str()
            .map(|s| Value::Text(s.into()))
            .unwrap_or_else(|_| Value::Undecodable("ENUM".into())),
        ValueRef::List(..) => Value::Undecodable("LIST".into()),
        ValueRef::Struct(..) => Value::Undecodable("STRUCT".into()),
        ValueRef::Array(..) => Value::Undecodable("ARRAY".into()),
        ValueRef::Map(..) => Value::Undecodable("MAP".into()),
        ValueRef::Union(..) => Value::Undecodable("UNION".into()),
        other => Value::Undecodable(format!("{:?}", other.data_type())),
    }
}

fn duck_uuid_ref_to_value(v: ValueRef<'_>) -> Value {
    match v {
        ValueRef::Null => Value::Null,
        ValueRef::Text(bytes) => std::str::from_utf8(bytes)
            .ok()
            .and_then(|text| text.parse().ok())
            .map(Value::Uuid)
            .unwrap_or_else(|| Value::Undecodable("UUID".into())),
        _ => Value::Undecodable("UUID".into()),
    }
}

fn rust_decimal_or_text(decimal: duckdb::types::Decimal) -> Value {
    decimal
        .try_into()
        .map(Value::Decimal)
        .unwrap_or_else(|_| Value::Text(decimal.to_string()))
}

fn values_to_duck_params(params: &[Value]) -> Result<Vec<duckdb::types::Value>, DriverError> {
    params
        .iter()
        .map(|p| {
            Ok(match p {
                Value::Null => duckdb::types::Value::Null,
                Value::Bool(b) => duckdb::types::Value::Boolean(*b),
                Value::Int(i) => duckdb::types::Value::BigInt(*i),
                Value::Float(f) => duckdb::types::Value::Double(*f),
                Value::Text(s) => duckdb::types::Value::Text(s.clone()),
                Value::Bytes(b) => duckdb::types::Value::Blob(b.clone()),
                Value::Date(d) => temporal::date_param(*d),
                Value::Time(t) => temporal::time_param(*t),
                Value::DateTime(dt) => temporal::timestamp_param(*dt),
                Value::TimestampTz(ts) => duckdb::types::Value::Text(ts.to_rfc3339()),
                Value::Decimal(d) => duckdb::types::Value::Decimal((*d).into()),
                Value::Uuid(u) => duckdb::types::Value::Text(u.to_string()),
                Value::Json(j) => duckdb::types::Value::Text(j.to_string()),
                Value::Undecodable(_) => {
                    return Err(DriverError::Unsupported(
                        "undecodable cell cannot be bound as a parameter".into(),
                    ));
                }
            })
        })
        .collect()
}

fn quote_ident(name: &str) -> String {
    format!("\"{}\"", name.replace('"', "\"\""))
}

fn qualified(schema: Option<&str>, table: &str) -> String {
    match schema {
        Some(s) if !s.is_empty() => format!("{}.{}", quote_ident(s), quote_ident(table)),
        _ => quote_ident(table),
    }
}

async fn blocking<T: Send + 'static>(
    f: impl FnOnce() -> Result<T, DriverError> + Send + 'static,
) -> Result<T, DriverError> {
    tokio::task::spawn_blocking(f)
        .await
        .map_err(|e| DriverError::Internal(format!("duckdb task join: {e}")))?
}

fn map_duck_error(err: duckdb::Error) -> DriverError {
    DriverError::Query {
        message: err.to_string(),
        sqlstate: None,
        position: None,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[cfg(target_os = "linux")]
    #[test]
    fn read_only_flat_file_open_does_not_block_if_path_is_replaced_with_a_fifo() {
        use std::time::Duration;

        let dir = tempfile::tempdir().unwrap();
        let fifo = dir.path().join("race.csv");
        std::fs::write(&fifo, "id\n7\n").unwrap();
        let expected = std::fs::metadata(&fifo).unwrap();
        std::fs::remove_file(&fifo).unwrap();
        let status = std::process::Command::new("mkfifo").arg(&fifo).status().unwrap();
        assert!(status.success());

        let path = fifo.clone();
        let (sender, receiver) = std::sync::mpsc::channel();
        let opener = std::thread::spawn(move || {
            let result = open_selected_file(&path, &expected).map(|_| ());
            let _ = sender.send(result);
        });
        let result = receiver
            .recv_timeout(Duration::from_secs(1))
            .expect("opening the selected path must not hang on a FIFO");
        opener.join().unwrap();
        assert!(matches!(result, Err(DriverError::PolicyDenied(_))));
    }

    async fn in_memory_connection() -> Box<dyn Connection> {
        DuckdbDriver
            .connect(ConnectOptions {
                database: ":memory:".into(),
                ..Default::default()
            })
            .await
            .unwrap()
    }

    #[tokio::test]
    async fn open_session_is_refused() {
        let conn = in_memory_connection().await;

        match conn.open_session().await {
            Err(DriverError::Unsupported(_)) => {}
            Ok(_) => panic!("duckdb must refuse open_session"),
            Err(other) => panic!("expected Unsupported, got {other:?}"),
        }
    }

    #[tokio::test]
    async fn a_timed_out_query_reports_an_unknown_outcome() {
        let conn = in_memory_connection().await;
        let control = tablepro_core::OperationControl::with_timeout(std::time::Duration::from_millis(5));

        let result = conn
            .query_controlled("SELECT count(*) FROM range(100000000) a, range(2) b", &control)
            .await;

        match result {
            Err(DriverError::OperationOutcomeUnknown { .. }) => {}
            other => panic!("expected OperationOutcomeUnknown, got {other:?}"),
        }
    }

    #[tokio::test]
    async fn binary_sql_exports_round_trip_null_empty_and_every_byte() {
        let conn = DuckdbDriver
            .connect(ConnectOptions {
                database: ":memory:".into(),
                ..Default::default()
            })
            .await
            .unwrap();
        conn.execute("CREATE TABLE binary_exports (id INTEGER, payload BLOB)")
            .await
            .unwrap();
        let columns = conn.fetch_columns(None, "binary_exports").await.unwrap();
        let values = [Value::Null, Value::Bytes(vec![]), Value::Bytes((0u8..=255).collect())];
        for (id, value) in values.iter().enumerate() {
            let sql = tablepro_core::sql_literal::build_insert_literal(
                "duckdb",
                None,
                "binary_exports",
                &columns,
                &[Value::Int(id as i64), value.clone()],
            )
            .unwrap();
            conn.execute(&sql).await.unwrap();
        }
        assert_eq!(
            conn.query("SELECT payload FROM binary_exports ORDER BY id")
                .await
                .unwrap()
                .rows,
            values.into_iter().map(|value| vec![value]).collect::<Vec<_>>()
        );
    }

    #[test]
    fn undecodable_cell_cannot_be_bound_as_null() {
        assert!(matches!(
            values_to_duck_params(&[Value::Undecodable("DECIMAL".into())]),
            Err(DriverError::Unsupported(_))
        ));
    }

    #[test]
    fn intervals_preserve_signed_components_and_refuse_submicrosecond_values() {
        assert_eq!(
            duck_value_ref_to_value(
                ValueRef::Interval {
                    months: -2,
                    days: 3,
                    nanos: -1_000,
                },
                false
            ),
            Value::Text("-2 months 3 days -1 microsecond".into())
        );
        assert!(matches!(
            duck_value_ref_to_value(
                ValueRef::Interval {
                    months: 0,
                    days: 0,
                    nanos: 1,
                },
                false
            ),
            Value::Undecodable(_)
        ));
    }

    #[test]
    fn unsigned_bigint_keeps_the_signed_boundary_exact() {
        assert_eq!(
            duck_value_ref_to_value(ValueRef::UBigInt(i64::MAX as u64), false),
            Value::Int(i64::MAX)
        );
        assert_eq!(
            duck_value_ref_to_value(ValueRef::UBigInt(i64::MAX as u64 + 1), false),
            Value::Text("9223372036854775808".into())
        );
    }

    #[test]
    fn structure_metadata_is_not_declared_without_a_fetch() {
        let d = DuckdbDriver;
        let source = include_str!("lib.rs");
        assert!(!d.supports_index_metadata());
        assert!(!d.supports_foreign_key_metadata());
        assert!(!source.contains(&["async fn ", "fetch_indexes("].concat()));
        assert!(!source.contains(&["async fn ", "fetch_foreign_keys("].concat()));
    }
    use tempfile::TempDir;

    #[test]
    fn driver_metadata() {
        let d = DuckdbDriver;
        assert_eq!(d.id(), "duckdb");
        assert_eq!(d.display_name(), "DuckDB");
        assert!(d.is_file_based());
        assert_eq!(d.default_port(), 0);
        assert_eq!(d.default_database(), "");
        assert_eq!(d.default_username(), "");
    }

    #[test]
    fn quote_ident_doubles_quotes() {
        assert_eq!(quote_ident("users"), "\"users\"");
        assert_eq!(quote_ident("a\"b"), "\"a\"\"b\"");
    }

    #[tokio::test]
    async fn connect_create_and_list_tables() {
        let dir = TempDir::new().unwrap();
        let path = dir.path().join("test.duckdb");
        let driver = DuckdbDriver;
        let conn = driver
            .connect(ConnectOptions {
                database: path.to_string_lossy().into(),
                ..Default::default()
            })
            .await
            .unwrap();
        conn.execute("CREATE TABLE foo (id INTEGER, name VARCHAR)")
            .await
            .unwrap();
        conn.execute("INSERT INTO foo VALUES (1, 'a'), (2, 'b')").await.unwrap();
        let tables = conn.list_tables().await.unwrap();
        assert!(tables.iter().any(|t| t.name == "foo"));
        let cols = conn.fetch_columns(None, "foo").await.unwrap();
        assert_eq!(cols.len(), 2);
        let rows = conn.fetch_rows(None, "foo", 0, 10).await.unwrap();
        assert_eq!(rows.rows.len(), 2);
    }
    #[tokio::test]
    async fn columns_are_read_for_a_table_whose_name_needs_quoting() {
        let driver = DuckdbDriver;
        let conn = driver.connect(ConnectOptions::default()).await.unwrap();
        conn.execute("CREATE TABLE \"O'Brien\" (id INTEGER, note VARCHAR)")
            .await
            .unwrap();

        let columns = conn.fetch_columns(None, "O'Brien").await.unwrap();

        assert_eq!(
            columns.iter().map(|c| c.name.as_str()).collect::<Vec<_>>(),
            vec!["id", "note"],
            "the table name reaches the catalog query as a bound value"
        );
    }

    #[test]
    fn flat_files_open_with_quoted_paths_and_expected_rows() {
        let dir = TempDir::new().unwrap();
        for (extension, contents) in [
            ("csv", "id,name\n1,Ada\n2,Grace\n"),
            ("tsv", "id\tname\n1\tAda\n2\tGrace\n"),
            ("json", "[{\"id\":1,\"name\":\"Ada\"},{\"id\":2,\"name\":\"Grace\"}]"),
        ] {
            let path = dir.path().join(format!("1 O'Brien data.{extension}"));
            std::fs::write(&path, contents).unwrap();
            let conn = open_path(path.to_str().unwrap()).unwrap();
            let table = quote_ident(&derive_view_name(path.to_str().unwrap()));
            let count: i64 = conn
                .query_row(&format!("SELECT count(*) FROM {table}"), [], |row| row.get(0))
                .unwrap();
            assert_eq!(count, 2, "{extension}");
        }
    }

    #[test]
    fn parquet_and_json_functions_work_without_extension_downloads() {
        let dir = TempDir::new().unwrap();
        let path = dir.path().join("O'Brien.parquet");
        let conn = DuckConnection::open_in_memory().unwrap();
        conn.execute_batch("SET autoinstall_known_extensions=false; SET autoload_known_extensions=false;")
            .unwrap();
        let count: i64 = conn
            .query_row("SELECT json_array_length('[1,2]')", [], |row| row.get(0))
            .unwrap();
        assert_eq!(count, 2);
        conn.execute_batch(&format!(
            "COPY (SELECT 1 AS id) TO '{}' (FORMAT PARQUET)",
            escape_duckdb_literal(path.to_str().unwrap())
        ))
        .unwrap();
        let reopened = open_path(path.to_str().unwrap()).unwrap();
        let count: i64 = reopened
            .query_row(
                &format!(
                    "SELECT count(*) FROM {}",
                    quote_ident(&derive_view_name(path.to_str().unwrap()))
                ),
                [],
                |row| row.get(0),
            )
            .unwrap();
        assert_eq!(count, 1);
    }

    #[test]
    fn malformed_or_missing_flat_files_report_errors() {
        let dir = TempDir::new().unwrap();
        for extension in ["json", "parquet"] {
            let path = dir.path().join(format!("broken.{extension}"));
            std::fs::write(&path, "not valid data {{{").unwrap();
            assert!(open_path(path.to_str().unwrap()).is_err());
        }
        assert!(open_path(dir.path().join("missing.csv").to_str().unwrap()).is_err());
    }
}
