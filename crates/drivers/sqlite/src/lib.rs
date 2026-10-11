use std::collections::HashMap;
use std::str::FromStr;
use std::time::Duration;

use async_trait::async_trait;
use sqlparser::ast::{Query, SetExpr, TableFactor, TableWithJoins};
use sqlparser::dialect::SQLiteDialect;
use sqlparser::parser::Parser;
use sqlx::pool::PoolConnection;
use sqlx::sqlite::{SqliteConnectOptions, SqlitePoolOptions, SqliteRow};
use sqlx::{
    Column, Executor as SqlxExecutor, Pool, Row, SqlSafeStr, Sqlite, SqliteConnection as SqlxSqliteConnection,
    Statement as SqlxStatement, TypeInfo, ValueRef,
};

use futures::stream::StreamExt;

use tablepro_core::{
    ColumnInfo, ConnectOptions, Connection, DatabaseDriver, DriverError, ExecResult, ForeignKeyInfo, IndexInfo,
    MAX_QUERY_ROWS, OperationControl, QueryResult, QueryResultBudget, TableInfo, Value, check_pre_dispatch,
    run_controlled_setup, run_server_cancellable,
};

mod interrupt;
mod session;
mod transaction;

use interrupt::InterruptHandle;

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

    fn supports_index_metadata(&self) -> bool {
        true
    }

    fn supports_foreign_key_metadata(&self) -> bool {
        true
    }

    async fn connect(&self, opts: ConnectOptions) -> Result<Box<dyn Connection>, DriverError> {
        let in_memory = opts.database.is_empty() || opts.database == ":memory:";
        let url = if in_memory {
            "sqlite::memory:".to_string()
        } else {
            format!("sqlite:{}", opts.database)
        };
        let connect_opts = SqliteConnectOptions::from_str(&url)
            .map_err(map_sqlx_error)?
            .create_if_missing(!opts.read_only)
            .read_only(opts.read_only && !in_memory);
        let session_options = (!in_memory).then(|| connect_opts.clone());
        let pool = SqlitePoolOptions::new()
            .max_connections(4)
            .acquire_timeout(Duration::from_secs(5))
            .connect_with(connect_opts)
            .await
            .map_err(map_sqlx_error)?;
        Ok(Box::new(SqliteConnection { pool, session_options }))
    }
}

struct SqliteConnection {
    pool: Pool<Sqlite>,
    session_options: Option<SqliteConnectOptions>,
}

// Catalog reads use the table-valued `pragma_*()` form. A bare PRAGMA
// statement answers from the connection's cached schema and can miss a table
// another pooled connection just created; a SELECT re-checks the schema when
// it is prepared. `foreign_key_list.to` is NULL when a key references the
// parent's primary key implicitly.
impl SqliteConnection {
    async fn primary_key_columns(&self, table: &str) -> Result<Vec<String>, DriverError> {
        sqlx::query_scalar("SELECT name FROM pragma_table_info(?) WHERE pk > 0 ORDER BY pk")
            .bind(table)
            .fetch_all(&self.pool)
            .await
            .map_err(map_sqlx_error)
    }
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
        let rows = sqlx::query("SELECT * FROM pragma_table_xinfo(?)")
            .bind(table)
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
                ColumnInfo {
                    name,
                    data_type,
                    nullable: r.get::<i64, _>(3) == 0,
                    primary_key,
                    is_auto_increment,
                    default_value: dflt,
                    is_generated,
                    comment: None,
                    collation: None,
                    enum_type: None,
                    domain_type: None,
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
        let mut connection = self.pool.acquire().await.map_err(map_sqlx_error)?;
        stream_into_result(&mut connection, &sql, limit as usize).await
    }

    async fn query(&self, sql: &str) -> Result<QueryResult, DriverError> {
        let mut connection = self.pool.acquire().await.map_err(map_sqlx_error)?;
        stream_into_result(&mut connection, sql, MAX_QUERY_ROWS).await
    }

    async fn query_params(&self, sql: &str, params: &[Value]) -> Result<QueryResult, DriverError> {
        let mut connection = self.pool.acquire().await.map_err(map_sqlx_error)?;
        params_into_result(&mut connection, sql, params, MAX_QUERY_ROWS).await
    }

    async fn query_controlled(&self, sql: &str, control: &OperationControl) -> Result<QueryResult, DriverError> {
        self.query_params_controlled(sql, &[], control).await
    }

    async fn open_session(&self) -> Result<Box<dyn tablepro_core::Session>, DriverError> {
        match &self.session_options {
            Some(options) => session::open(options).await,
            None => Err(DriverError::Unsupported(
                "dedicated sessions on an in-memory database, which each connection sees separately".into(),
            )),
        }
    }

    async fn query_params_controlled(
        &self,
        sql: &str,
        params: &[Value],
        control: &OperationControl,
    ) -> Result<QueryResult, DriverError> {
        let mut connection = acquire_controlled(&self.pool, control).await?;
        let handle = InterruptHandle::of(&mut connection).await?;
        let result = run_server_cancellable(
            params_into_result(&mut connection, sql, params, MAX_QUERY_ROWS),
            request_interrupt(&handle),
            confirms_cancellation,
            control,
        )
        .await;
        release_connection(connection, &result).await;
        result
    }

    async fn execute(&self, sql: &str) -> Result<ExecResult, DriverError> {
        let res = sqlx::query(sqlx::AssertSqlSafe(sql))
            .execute(&self.pool)
            .await
            .map_err(map_sqlx_error)?;
        Ok(ExecResult {
            rows_affected: res.rows_affected(),
        })
    }

    async fn execute_params(&self, sql: &str, params: &[Value]) -> Result<ExecResult, DriverError> {
        let q = bind_sqlite_params(sqlx::query(sqlx::AssertSqlSafe(sql)), params)?;
        let res = q.execute(&self.pool).await.map_err(map_sqlx_error)?;
        Ok(ExecResult {
            rows_affected: res.rows_affected(),
        })
    }

    async fn execute_controlled(&self, sql: &str, control: &OperationControl) -> Result<ExecResult, DriverError> {
        self.execute_params_controlled(sql, &[], control).await
    }

    async fn execute_params_controlled(
        &self,
        sql: &str,
        params: &[Value],
        control: &OperationControl,
    ) -> Result<ExecResult, DriverError> {
        let mut connection = acquire_controlled(&self.pool, control).await?;
        let handle = InterruptHandle::of(&mut connection).await?;
        let result = run_server_cancellable(
            execute_on(&mut *connection, sql, params),
            request_interrupt(&handle),
            confirms_cancellation,
            control,
        )
        .await;
        release_connection(connection, &result).await;
        result
    }

    fn supports_server_cancellation(&self) -> bool {
        true
    }

    async fn execute_in_transaction(&self, statements: &[(String, Vec<Value>)]) -> Result<Vec<u64>, DriverError> {
        self.execute_in_transaction_checked(statements, &[]).await
    }

    async fn execute_in_transaction_checked(
        &self,
        statements: &[(String, Vec<Value>)],
        expect_one: &[usize],
    ) -> Result<Vec<u64>, DriverError> {
        transaction::execute_in_transaction_checked(&self.pool, statements, expect_one).await
    }

    async fn fetch_indexes(&self, _schema: Option<&str>, table: &str) -> Result<Vec<IndexInfo>, DriverError> {
        // SQLite catalog access is via PRAGMAs — they're scoped to the
        // current database file (no schema parameter needed). For each
        // entry from index_list we issue an index_info to get column
        // ordering. PK index doesn't always show up in index_list (a
        // bare INTEGER PRIMARY KEY uses the rowid alias, no real
        // index), so we synthesise one from table_info if missing.
        let list = sqlx::query("SELECT * FROM pragma_index_list(?)")
            .bind(table)
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
            let info_rows = sqlx::query("SELECT * FROM pragma_index_info(?)")
                .bind(&name)
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
                predicate: None,
            });
        }
        if !saw_primary {
            // Synthesise the implicit PK index from PRAGMA table_info
            // so the UI can render PK columns even when SQLite chose
            // the rowid-alias path.
            let pk_cols = self.primary_key_columns(table).await?;
            if !pk_cols.is_empty() {
                out.push(IndexInfo {
                    name: "PRIMARY".into(),
                    columns: pk_cols,
                    unique: true,
                    primary: true,
                    predicate: None,
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
        let rows = sqlx::query("SELECT * FROM pragma_foreign_key_list(?) ORDER BY id, seq")
            .bind(table)
            .fetch_all(&self.pool)
            .await
            .map_err(map_sqlx_error)?;
        let mut by_id: std::collections::BTreeMap<i64, ForeignKeyInfo> = std::collections::BTreeMap::new();
        for r in rows {
            let id: i64 = r.try_get(0).unwrap_or(0);
            let ref_table: String = r.try_get(2).unwrap_or_default();
            let from_col: String = r.try_get(3).unwrap_or_default();
            let to_col: String = r.try_get::<Option<String>, _>(4).ok().flatten().unwrap_or_default();
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
        let mut keys: Vec<ForeignKeyInfo> = by_id.into_values().collect();
        for key in &mut keys {
            if key.ref_columns.iter().all(String::is_empty) {
                key.ref_columns = self.primary_key_columns(&key.ref_table).await?;
            }
        }
        Ok(keys)
    }

    async fn ping(&self) -> Result<(), DriverError> {
        sqlx::query("SELECT 1")
            .execute(&self.pool)
            .await
            .map_err(map_sqlx_error)?;
        Ok(())
    }

    async fn begin(&self) -> Result<Box<dyn tablepro_core::Transaction>, DriverError> {
        let tx = self.pool.begin().await.map_err(map_sqlx_error)?;
        Ok(Box::new(SqliteTransaction { tx: Some(tx) }))
    }

    async fn server_version(&self) -> Result<Option<String>, DriverError> {
        let row = sqlx::query("SELECT sqlite_version()")
            .fetch_one(&self.pool)
            .await
            .map_err(map_sqlx_error)?;
        let v: String = row.try_get(0).unwrap_or_default();
        Ok(Some(format!("SQLite {v}")))
    }

    async fn close(self: Box<Self>) -> Result<(), DriverError> {
        self.pool.close().await;
        Ok(())
    }
}

struct SqliteTransaction {
    tx: Option<sqlx::Transaction<'static, Sqlite>>,
}

#[async_trait]
impl tablepro_core::Transaction for SqliteTransaction {
    async fn query(&mut self, sql: &str) -> Result<QueryResult, DriverError> {
        let tx = self
            .tx
            .as_mut()
            .ok_or_else(|| DriverError::Internal("transaction closed".into()))?;
        stream_into_result(tx, sql, MAX_QUERY_ROWS).await
    }

    async fn execute(&mut self, sql: &str) -> Result<ExecResult, DriverError> {
        let tx = self
            .tx
            .as_mut()
            .ok_or_else(|| DriverError::Internal("transaction closed".into()))?;
        let res = sqlx::query(sqlx::AssertSqlSafe(sql))
            .execute(&mut **tx)
            .await
            .map_err(map_sqlx_error)?;
        Ok(ExecResult {
            rows_affected: res.rows_affected(),
        })
    }

    async fn commit(mut self: Box<Self>) -> Result<(), DriverError> {
        let tx = self
            .tx
            .take()
            .ok_or_else(|| DriverError::Internal("transaction closed".into()))?;
        tx.commit().await.map_err(map_sqlx_error)
    }

    async fn rollback(mut self: Box<Self>) -> Result<(), DriverError> {
        let tx = self
            .tx
            .take()
            .ok_or_else(|| DriverError::Internal("transaction closed".into()))?;
        tx.rollback().await.map_err(map_sqlx_error)
    }
}

async fn stream_into_result(
    connection: &mut SqlxSqliteConnection,
    sql: &str,
    limit: usize,
) -> Result<QueryResult, DriverError> {
    let statement = connection
        .prepare(sqlx::AssertSqlSafe(sql).into_sql_str())
        .await
        .map_err(map_sqlx_error)?;
    let columns = result_columns(connection, statement.columns(), sql).await;
    drop(statement);
    let mut stream = sqlx::query(sqlx::AssertSqlSafe(sql)).fetch(&mut *connection);
    let mut rows: Vec<Vec<Value>> = Vec::new();
    let mut budget = QueryResultBudget::default();
    let mut truncated = false;
    while let Some(row_result) = stream.next().await {
        let row = row_result.map_err(map_sqlx_error)?;
        if rows.len() >= limit {
            truncated = true;
            break;
        }
        let values = (0..columns.len())
            .map(|index| extract_value(&row, index))
            .collect::<Vec<_>>();
        if !budget.admit(&values) {
            truncated = true;
            break;
        }
        rows.push(values);
    }
    drop(stream);
    Ok(QueryResult {
        columns,
        rows,
        truncated,
    })
}

async fn result_columns(
    connection: &mut SqlxSqliteConnection,
    source_columns: &[sqlx::sqlite::SqliteColumn],
    sql: &str,
) -> Vec<ColumnInfo> {
    let mut columns: Vec<ColumnInfo> = source_columns
        .iter()
        .map(|c| ColumnInfo {
            name: c.name().to_string(),
            data_type: c.type_info().name().to_string(),
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
        .collect();
    resolve_result_column_types(connection, source_columns, &mut columns, sql).await;
    columns
}

async fn resolve_result_column_types(
    connection: &mut SqlxSqliteConnection,
    source_columns: &[sqlx::sqlite::SqliteColumn],
    columns: &mut [ColumnInfo],
    sql: &str,
) {
    let unknown_origins = source_columns
        .iter()
        .enumerate()
        .filter_map(|(index, column)| {
            (columns[index].data_type == "NULL")
                .then(|| column.origin().table_column().cloned().map(|origin| (index, origin)))
                .flatten()
        })
        .collect::<Vec<_>>();
    if !unknown_origins.is_empty() && !result_origin_is_ambiguous(sql) {
        let mut table_types: HashMap<(String, String), HashMap<String, String>> = HashMap::new();
        let mut attached_schemas = None;
        let mut attached_schema_lookup_failed = false;
        for (index, origin) in unknown_origins {
            let origin_table = origin.table.as_ref();
            // SQLx flattens attached origins to "schema.table", which can also
            // be a main-schema table name. Use declared metadata only if unique.
            let mut candidates = vec![("main".to_string(), origin_table.to_string())];
            if origin_table.contains('.') {
                if attached_schemas.is_none() && !attached_schema_lookup_failed {
                    match attached_database_names(connection).await {
                        Some(schemas) => attached_schemas = Some(schemas),
                        None => attached_schema_lookup_failed = true,
                    }
                }
                if attached_schema_lookup_failed {
                    continue;
                }
                if let Some(schemas) = attached_schemas.as_ref() {
                    for schema in schemas {
                        if let Some(table) = origin_table.strip_prefix(&format!("{schema}.")) {
                            candidates.push((schema.clone(), table.to_string()));
                        }
                    }
                }
            }

            let mut declared_type = None;
            let mut matches = 0;
            for (schema, table) in candidates {
                let key = (schema.clone(), table.clone());
                if !table_types.contains_key(&key) {
                    let declared = declared_table_columns(connection, &schema, &table).await;
                    table_types.insert(key.clone(), declared);
                }
                if let Some(data_type) = table_types.get(&key).and_then(|types| types.get(origin.name.as_ref())) {
                    matches += 1;
                    declared_type = Some(data_type.clone());
                    if matches > 1 {
                        break;
                    }
                }
            }
            if matches == 1
                && let Some(data_type) = declared_type
            {
                columns[index].data_type = data_type;
            }
        }
    }
}

fn result_origin_is_ambiguous(sql: &str) -> bool {
    let Ok(statements) = Parser::parse_sql(&SQLiteDialect {}, sql) else {
        // Preserve SQLx's fallback metadata when the query shape is unknown.
        return true;
    };
    statements.iter().any(|statement| {
        let sqlparser::ast::Statement::Query(query) = statement else {
            return false;
        };
        query_has_compound_output(query)
    })
}

fn query_has_compound_output(query: &Query) -> bool {
    query
        .with
        .as_ref()
        .is_some_and(|with| with.cte_tables.iter().any(|cte| query_has_compound_output(&cte.query)))
        || match query.body.as_ref() {
            SetExpr::SetOperation { .. } => true,
            SetExpr::Query(query) => query_has_compound_output(query),
            SetExpr::Select(select) => select.from.iter().any(table_has_compound_output),
            _ => false,
        }
}

fn table_has_compound_output(table: &TableWithJoins) -> bool {
    table_factor_has_compound_output(&table.relation)
        || table
            .joins
            .iter()
            .any(|join| table_factor_has_compound_output(&join.relation))
}

fn table_factor_has_compound_output(table: &TableFactor) -> bool {
    match table {
        TableFactor::Derived { subquery, .. } => query_has_compound_output(subquery),
        _ => false,
    }
}

async fn attached_database_names(connection: &mut SqlxSqliteConnection) -> Option<Vec<String>> {
    sqlx::query_scalar("SELECT name FROM pragma_database_list WHERE name <> 'main'")
        .fetch_all(&mut *connection)
        .await
        .ok()
}

async fn declared_table_columns(
    connection: &mut SqlxSqliteConnection,
    schema: &str,
    table: &str,
) -> HashMap<String, String> {
    sqlx::query("SELECT name, type FROM pragma_table_xinfo(?, ?)")
        .bind(table)
        .bind(schema)
        .fetch_all(&mut *connection)
        .await
        .ok()
        .into_iter()
        .flatten()
        .filter_map(|row| Some((row.try_get::<String, _>(0).ok()?, row.try_get::<String, _>(1).ok()?)))
        .collect()
}

fn extract_value(row: &SqliteRow, idx: usize) -> Value {
    // SQLite's non-optional decoders turn NULL into zero/empty values.
    // Inspect the storage value before using the declared column type.
    match row.try_get_raw(idx) {
        Ok(value) if value.is_null() => return Value::Null,
        Err(_) => return Value::Undecodable(row.columns()[idx].type_info().name().to_string()),
        Ok(_) => {}
    }
    let type_name = row.columns()[idx].type_info().name().to_ascii_uppercase();
    let runtime_type = row
        .try_get_raw(idx)
        .map(|value| value.type_info().name().to_ascii_uppercase())
        .unwrap_or_default();
    match type_name.as_str() {
        "INTEGER" => row
            .try_get::<i64, _>(idx)
            .map(Value::Int)
            .unwrap_or_else(|_| decode_fallback(row, idx)),
        "REAL" => row
            .try_get::<f64, _>(idx)
            .map(Value::Float)
            .unwrap_or_else(|_| decode_fallback(row, idx)),
        "BLOB" => match runtime_type.as_str() {
            "TEXT" => row
                .try_get::<String, _>(idx)
                .map(Value::Text)
                .unwrap_or_else(|_| decode_fallback(row, idx)),
            "INTEGER" => row
                .try_get::<i64, _>(idx)
                .map(Value::Int)
                .unwrap_or_else(|_| decode_fallback(row, idx)),
            "REAL" => row
                .try_get::<f64, _>(idx)
                .map(Value::Float)
                .unwrap_or_else(|_| decode_fallback(row, idx)),
            _ => row
                .try_get::<Vec<u8>, _>(idx)
                .map(Value::Bytes)
                .unwrap_or_else(|_| decode_fallback(row, idx)),
        },
        "BOOLEAN" => row
            .try_get::<bool, _>(idx)
            .map(Value::Bool)
            .unwrap_or_else(|_| decode_fallback(row, idx)),
        "DATE" => row
            .try_get::<chrono::NaiveDate, _>(idx)
            .map(Value::Date)
            .or_else(|_| row.try_get::<String, _>(idx).map(Value::Text))
            .unwrap_or_else(|_| decode_fallback(row, idx)),
        "TIME" => row
            .try_get::<chrono::NaiveTime, _>(idx)
            .map(Value::Time)
            .or_else(|_| row.try_get::<String, _>(idx).map(Value::Text))
            .unwrap_or_else(|_| decode_fallback(row, idx)),
        "DATETIME" | "TIMESTAMP" => row
            .try_get::<chrono::NaiveDateTime, _>(idx)
            .map(Value::DateTime)
            .or_else(|_| row.try_get::<String, _>(idx).map(Value::Text))
            .unwrap_or_else(|_| decode_fallback(row, idx)),
        _ => untyped_value(row, idx),
    }
}

/// A column with no declared type - every expression, aggregate and
/// `count(*)` - reaches here. SQLite decides the value's type at
/// runtime, so the decode is tried in the order the storage classes can
/// hold, and `Option` keeps a real NULL distinct from a type mismatch.
fn untyped_value(row: &SqliteRow, idx: usize) -> Value {
    if let Ok(value) = row.try_get::<Option<i64>, _>(idx) {
        return value.map_or(Value::Null, Value::Int);
    }
    if let Ok(value) = row.try_get::<Option<f64>, _>(idx) {
        return value.map_or(Value::Null, Value::Float);
    }
    if let Ok(value) = row.try_get::<Option<String>, _>(idx) {
        return value.map_or(Value::Null, Value::Text);
    }
    row.try_get::<Vec<u8>, _>(idx)
        .map(Value::Bytes)
        .unwrap_or_else(|_| Value::Undecodable(row.columns()[idx].type_info().name().to_string()))
}

/// A declared column type is a hint, not a guarantee -- SQLite's type
/// affinity can still store a row's actual value in a different
/// storage class than the column's declared type. When the declared
/// type's own decode fails, this is reached to find out whether the
/// value is genuinely NULL or just stored as text/bytes instead, so a
/// real value is never silently shown as an empty cell.
fn decode_fallback(row: &SqliteRow, idx: usize) -> Value {
    untyped_value(row, idx)
}

fn bind_sqlite_params<'q>(
    mut q: sqlx::query::Query<'q, Sqlite, sqlx::sqlite::SqliteArguments>,
    params: &'q [Value],
) -> Result<sqlx::query::Query<'q, Sqlite, sqlx::sqlite::SqliteArguments>, DriverError> {
    for p in params {
        q = match p {
            Value::Null => q.bind(Option::<&str>::None),
            Value::Bool(b) => q.bind(*b),
            Value::Int(i) => q.bind(*i),
            Value::Float(f) if f.is_nan() || (*f == 0.0 && f.is_sign_negative()) => {
                return Err(DriverError::Unsupported(
                    "SQLite cannot preserve NaN or negative zero as a REAL value".into(),
                ));
            }
            Value::Float(f) => q.bind(*f),
            Value::Text(s) => q.bind(s.clone()),
            Value::Bytes(b) => q.bind(b.clone()),
            Value::Date(d) => q.bind(*d),
            Value::Time(t) => q.bind(*t),
            Value::DateTime(dt) => q.bind(*dt),
            Value::TimestampTz(ts) => q.bind(*ts),
            Value::Decimal(d) => match exact_real(d) {
                Some(real) => q.bind(real),
                None => q.bind(d.to_string()),
            },
            Value::Uuid(u) => q.bind(u.to_string()),
            Value::Json(j) => q.bind(j.to_string()),
            Value::Undecodable(_) => {
                return Err(DriverError::Unsupported(
                    "undecodable cell cannot be bound as a parameter".into(),
                ));
            }
        };
    }
    Ok(q)
}

fn exact_real(decimal: &rust_decimal::Decimal) -> Option<f64> {
    let digits = decimal.normalize().to_string();
    digits.parse::<f64>().ok().filter(|real| real.to_string() == digits)
}

fn quote_ident(name: &str) -> String {
    format!("\"{}\"", name.replace('"', "\"\""))
}

async fn params_into_result(
    connection: &mut SqlxSqliteConnection,
    sql: &str,
    params: &[Value],
    limit: usize,
) -> Result<QueryResult, DriverError> {
    if params.is_empty() {
        return stream_into_result(connection, sql, limit).await;
    }
    let statement = connection
        .prepare(sqlx::AssertSqlSafe(sql).into_sql_str())
        .await
        .map_err(map_sqlx_error)?;
    let columns = result_columns(connection, statement.columns(), sql).await;
    drop(statement);
    let query = bind_sqlite_params(sqlx::query(sqlx::AssertSqlSafe(sql)), params)?;
    let mut stream = query.fetch(&mut *connection);
    let mut rows: Vec<Vec<Value>> = Vec::new();
    let mut budget = QueryResultBudget::default();
    let mut truncated = false;
    while let Some(row_result) = stream.next().await {
        let row = row_result.map_err(map_sqlx_error)?;
        if rows.len() >= limit {
            truncated = true;
            break;
        }
        let values = (0..columns.len())
            .map(|index| extract_value(&row, index))
            .collect::<Vec<_>>();
        if !budget.admit(&values) {
            truncated = true;
            break;
        }
        rows.push(values);
    }
    drop(stream);
    Ok(QueryResult {
        columns,
        rows,
        truncated,
    })
}

async fn execute_on<'e, E>(executor: E, sql: &str, params: &[Value]) -> Result<ExecResult, DriverError>
where
    E: sqlx::Executor<'e, Database = Sqlite>,
{
    let query = bind_sqlite_params(sqlx::query(sqlx::AssertSqlSafe(sql)), params)?;
    let result = query.execute(executor).await.map_err(map_sqlx_error)?;
    Ok(ExecResult {
        rows_affected: result.rows_affected(),
    })
}

async fn acquire_controlled(
    pool: &Pool<Sqlite>,
    control: &OperationControl,
) -> Result<PoolConnection<Sqlite>, DriverError> {
    check_pre_dispatch(control)?;
    run_controlled_setup(pool.acquire(), control)
        .await?
        .map_err(map_sqlx_error)
}

async fn request_interrupt(handle: &InterruptHandle) -> Result<(), DriverError> {
    handle.interrupt();
    Ok(())
}

/// SQLite raises `SQLITE_INTERRUPT` for a statement it aborted. sqlx
/// reports the extended result code, so both the plain code and an
/// extended code in the same family have to be accepted.
fn confirms_cancellation(error: &DriverError) -> bool {
    let DriverError::Query { message, sqlstate, .. } = error else {
        return false;
    };
    if sqlstate.as_deref() == Some("9") {
        return true;
    }
    message.to_lowercase().contains("interrupted")
}

async fn release_connection<T>(connection: PoolConnection<Sqlite>, result: &Result<T, DriverError>) {
    if matches!(result, Err(DriverError::OperationOutcomeUnknown { .. })) {
        drop(connection.detach());
    }
}

fn map_sqlx_error(err: sqlx::Error) -> DriverError {
    use sqlx::Error::*;
    match err {
        Database(e) => DriverError::Query {
            message: e.message().to_string(),
            sqlstate: e.code().map(|c| c.to_string()),
            position: None,
        },
        Io(e) if e.kind() == std::io::ErrorKind::ConnectionRefused => DriverError::ConnectionRefused,
        Tls(e) => DriverError::Tls(e.to_string()),
        PoolClosed | PoolTimedOut => DriverError::Disconnected,
        other => DriverError::Internal(format!("{other}")),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn structure_metadata_declarations_match_the_connection_impl() {
        let d = SqliteDriver;
        let source = include_str!("lib.rs");
        assert!(d.supports_index_metadata());
        assert!(d.supports_foreign_key_metadata());
        assert!(source.contains(&["async fn ", "fetch_indexes("].concat()));
        assert!(source.contains(&["async fn ", "fetch_foreign_keys("].concat()));
    }
    use tempfile::TempDir;

    fn opts_for(path: &str) -> ConnectOptions {
        ConnectOptions {
            database: path.to_string(),
            ..Default::default()
        }
    }

    #[tokio::test]
    async fn a_read_only_connection_cannot_write_even_when_sql_tries() {
        let dir = TempDir::new().unwrap();
        let path = dir.path().join("ro.db");
        let writer = SqliteDriver.connect(opts_for(path.to_str().unwrap())).await.unwrap();
        writer
            .execute("CREATE TABLE foo (id INTEGER PRIMARY KEY)")
            .await
            .unwrap();
        writer.execute("INSERT INTO foo VALUES (1)").await.unwrap();
        drop(writer);

        let reader = SqliteDriver
            .connect(ConnectOptions {
                read_only: true,
                ..opts_for(path.to_str().unwrap())
            })
            .await
            .unwrap();
        assert_eq!(reader.query("SELECT id FROM foo").await.unwrap().rows.len(), 1);
        for sql in [
            "INSERT INTO foo VALUES (2)",
            "CREATE TABLE bar (id INTEGER)",
            "DROP TABLE foo",
            "PRAGMA query_only = OFF",
        ] {
            let outcome = reader.execute(sql).await;
            let wrote = outcome.is_ok() && reader.query("SELECT id FROM foo").await.unwrap().rows.len() != 1;
            assert!(!wrote, "{sql} must not change a read-only database");
        }
        assert_eq!(reader.query("SELECT id FROM foo").await.unwrap().rows.len(), 1);
    }

    #[tokio::test]
    async fn a_read_only_connection_does_not_create_a_missing_file() {
        let dir = TempDir::new().unwrap();
        let path = dir.path().join("missing.db");
        let outcome = SqliteDriver
            .connect(ConnectOptions {
                read_only: true,
                ..opts_for(path.to_str().unwrap())
            })
            .await;
        assert!(outcome.is_err());
        assert!(!path.exists());
    }

    #[tokio::test]
    async fn driver_metadata() {
        let d = SqliteDriver;
        assert_eq!(d.id(), "sqlite");
        assert_eq!(d.display_name(), "SQLite");
        assert_eq!(d.default_port(), 0);
        assert_eq!(d.default_database(), "");
        assert_eq!(d.default_username(), "");
    }

    #[tokio::test]
    async fn an_expression_column_decodes_by_its_runtime_type() {
        let dir = TempDir::new().unwrap();
        let path = dir.path().join("untyped.db");
        let conn = SqliteDriver.connect(opts_for(path.to_str().unwrap())).await.unwrap();
        conn.execute("CREATE TABLE t (id INTEGER PRIMARY KEY, label TEXT)")
            .await
            .unwrap();
        conn.execute("INSERT INTO t (label) VALUES ('a'), ('b')").await.unwrap();

        let counted = conn.query("SELECT count(*) FROM t").await.unwrap();
        assert_eq!(counted.rows, vec![vec![Value::Int(2)]]);

        let mixed = conn
            .query("SELECT 1, 2.5, 'text', NULL, group_concat(label), CAST('text blob' AS BLOB) FROM t")
            .await
            .unwrap();
        assert_eq!(
            mixed.rows,
            vec![vec![
                Value::Int(1),
                Value::Float(2.5),
                Value::Text("text".into()),
                Value::Null,
                Value::Text("a,b".into()),
                Value::Bytes(b"text blob".to_vec()),
            ]]
        );
        let blob_oracle = conn
            .query("SELECT typeof(CAST('text blob' AS BLOB)), hex(CAST('text blob' AS BLOB))")
            .await
            .unwrap();
        assert_eq!(
            blob_oracle.rows,
            vec![vec![
                Value::Text("blob".into()),
                Value::Text("7465787420626C6F62".into())
            ]]
        );
    }

    #[tokio::test]
    async fn a_value_that_does_not_match_its_declared_column_type_keeps_its_text_instead_of_becoming_null() {
        let dir = TempDir::new().unwrap();
        let path = dir.path().join("affinity.db");
        let conn = SqliteDriver.connect(opts_for(path.to_str().unwrap())).await.unwrap();
        conn.execute("CREATE TABLE t (v REAL)").await.unwrap();
        // REAL/NUMERIC affinity only converts a string that looks
        // numeric; this one doesn't, so SQLite keeps it stored as
        // TEXT even though the column is declared REAL.
        conn.execute("INSERT INTO t (v) VALUES ('not-a-number')").await.unwrap();
        let result = conn.query("SELECT v FROM t").await.unwrap();
        assert_eq!(result.rows, vec![vec![Value::Text("not-a-number".into())]]);
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
}
