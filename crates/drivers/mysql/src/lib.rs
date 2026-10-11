use std::time::Duration;

use async_trait::async_trait;
use secrecy::ExposeSecret;
use sqlparser::ast::Statement as SqlStatement;
use sqlparser::dialect::MySqlDialect;
use sqlparser::parser::Parser;
use sqlx::mysql::{MySql, MySqlConnectOptions, MySqlPoolOptions, MySqlRow};
use sqlx::pool::PoolConnection;
use sqlx::{Column, Connection as SqlxConnection, Executor, Pool, Row, SqlSafeStr, Statement, TypeInfo, ValueRef};

use futures::stream::StreamExt;

mod packed;
mod session;
mod temporal;

use tablepro_core::{
    ColumnInfo, ConnectOptions, Connection, DatabaseDriver, DriverError, ExecResult, ForeignKeyInfo, IndexInfo,
    MAX_QUERY_ROWS, OperationControl, QueryResult, QueryResultBudget, TableInfo, Transport, Value, check_pre_dispatch,
    run_controlled_setup, run_server_cancellable,
};

/// Name of the SSH-forwarded rendezvous socket inside the private directory
/// `SshTunnel::open_chain_socket` creates. Not a real mysqld socket; just a
/// name shared between `forwarded_socket_name` (which tells the transport
/// layer to forward one) and `connect` (which dials it).
const FORWARDED_SOCKET_NAME: &str = "mysqld.sock";

pub struct MysqlDriver;

#[async_trait]
impl DatabaseDriver for MysqlDriver {
    fn supports_database_listing(&self) -> bool {
        true
    }

    fn id(&self) -> &'static str {
        "mysql"
    }

    fn display_name(&self) -> &'static str {
        "MySQL"
    }

    fn default_port(&self) -> u16 {
        3306
    }

    fn default_database(&self) -> &'static str {
        "mysql"
    }

    fn default_username(&self) -> &'static str {
        "root"
    }

    fn supports_index_metadata(&self) -> bool {
        true
    }

    fn supports_foreign_key_metadata(&self) -> bool {
        true
    }

    fn forwarded_socket_name(&self, _service_port: u16) -> Option<String> {
        Some(FORWARDED_SOCKET_NAME.to_string())
    }

    fn supports_client_tls_auth(&self) -> bool {
        true
    }

    async fn connect(&self, opts: ConnectOptions) -> Result<Box<dyn Connection>, DriverError> {
        let mysql_opts = mysql_connect_options(&opts);
        let cancellation_options = mysql_opts.clone();
        let session_options = mysql_opts.clone();
        let read_only = opts.read_only;
        let pool = MySqlPoolOptions::new()
            .max_connections(4)
            .acquire_timeout(Duration::from_secs(5))
            .after_connect(move |connection, _| Box::pin(prepare_session(connection, read_only)))
            .before_acquire(move |connection, _| {
                Box::pin(async move {
                    prepare_session(connection, read_only).await?;
                    Ok(true)
                })
            })
            .connect_with(mysql_opts)
            .await
            .map_err(map_sqlx_connect_error)?;
        // Lazy: a saved connection with a failed-login lockout policy
        // must not see two authentication attempts for one Connect
        // click. The real dial happens only when a cancel is actually
        // requested.
        let cancellation_pool = MySqlPoolOptions::new()
            .max_connections(1)
            .acquire_timeout(Duration::from_secs(5))
            .connect_lazy_with(cancellation_options);
        Ok(Box::new(MysqlConnection {
            pool,
            cancellation_pool,
            session_options,
            read_only,
        }))
    }
}

struct MysqlConnection {
    pool: Pool<MySql>,
    cancellation_pool: Pool<MySql>,
    session_options: MySqlConnectOptions,
    read_only: bool,
}

#[async_trait]
impl Connection for MysqlConnection {
    async fn list_databases(&self) -> Result<Vec<String>, DriverError> {
        let rows = sqlx::query(
            "SELECT CAST(schema_name AS CHAR) FROM information_schema.schemata
             WHERE schema_name NOT IN ('information_schema', 'mysql', 'performance_schema', 'sys')
             ORDER BY schema_name",
        )
        .fetch_all(&self.pool)
        .await
        .map_err(map_sqlx_error)?;
        Ok(rows.into_iter().map(|row| row.get::<String, _>(0)).collect())
    }

    async fn list_tables(&self) -> Result<Vec<TableInfo>, DriverError> {
        let rows = sqlx::query(
            "SELECT CAST(table_schema AS CHAR), CAST(table_name AS CHAR)
             FROM information_schema.tables
             WHERE table_schema = DATABASE()
             ORDER BY table_name",
        )
        .fetch_all(&self.pool)
        .await
        .map_err(map_sqlx_error)?;
        Ok(rows
            .into_iter()
            .map(|r| TableInfo {
                schema: Some(r.get::<String, _>(0)),
                name: r.get::<String, _>(1),
            })
            .collect())
    }

    async fn fetch_columns(&self, schema: Option<&str>, table: &str) -> Result<Vec<ColumnInfo>, DriverError> {
        // `column_type` is canonical: it carries the precision /
        // length the user typed (`tinyint(1)`, `varchar(255)`,
        // `decimal(10,2)`, `enum('a','b')`). `data_type` strips all
        // that — returns `tinyint` for both `tinyint(1)` and
        // `tinyint(4)`, which collapses MySQL's idiomatic boolean
        // type into a generic int and breaks the bool-detection
        // heuristic in `classify_type`. Prefer column_type for the
        // displayed `data_type`.
        let rows = sqlx::query(
            "SELECT CAST(column_name AS CHAR), CAST(column_type AS CHAR),
                    CAST(is_nullable AS CHAR), CAST(column_key AS CHAR),
                    CAST(extra AS CHAR), CAST(column_default AS CHAR),
                    CAST(generation_expression AS CHAR),
                    CAST(column_comment AS CHAR),
                    CAST(collation_name AS CHAR),
                    CAST(VERSION() LIKE '%MariaDB%' AS SIGNED)
             FROM information_schema.columns
             WHERE table_schema = COALESCE(?, DATABASE()) AND table_name = ?
             ORDER BY ordinal_position",
        )
        .bind(schema)
        .bind(table)
        .fetch_all(&self.pool)
        .await
        .map_err(map_sqlx_error)?;
        Ok(rows.iter().map(row_to_column_info).collect())
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
        let mut connection = self.pool.acquire().await.map_err(map_sqlx_error)?;
        params_into_result(&mut connection, &sql, &[], limit as usize).await
    }

    async fn query(&self, sql: &str) -> Result<QueryResult, DriverError> {
        let mut connection = self.pool.acquire().await.map_err(map_sqlx_error)?;
        params_into_result(&mut connection, sql, &[], MAX_QUERY_ROWS).await
    }

    async fn query_params(&self, sql: &str, params: &[Value]) -> Result<QueryResult, DriverError> {
        let mut connection = self.pool.acquire().await.map_err(map_sqlx_error)?;
        params_into_result(&mut connection, sql, params, MAX_QUERY_ROWS).await
    }

    async fn query_controlled(&self, sql: &str, control: &OperationControl) -> Result<QueryResult, DriverError> {
        self.query_params_controlled(sql, &[], control).await
    }

    async fn query_params_controlled(
        &self,
        sql: &str,
        params: &[Value],
        control: &OperationControl,
    ) -> Result<QueryResult, DriverError> {
        let mut connection = acquire_controlled(&self.pool, control).await?;
        let connection_id = connection_id_controlled(&mut connection, control).await?;
        let result = session::query_with_text_fallback(
            &mut connection,
            &self.cancellation_pool,
            connection_id,
            sql,
            params,
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
        let q = bind_mysql_params(sqlx::query(sqlx::AssertSqlSafe(sql)), params)?;
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
        let connection_id = connection_id_controlled(&mut connection, control).await?;
        let result = run_server_cancellable(
            execute_on(&mut *connection, sql, params),
            request_cancellation(&self.cancellation_pool, connection_id),
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
        validate_atomic_batch(statements)?;
        let mut tx = self.pool.begin().await.map_err(map_sqlx_error)?;
        let mut affected = Vec::with_capacity(statements.len());
        for (idx, (sql, params)) in statements.iter().enumerate() {
            let sql = sql.as_str();
            let q = match bind_mysql_params(sqlx::query(sqlx::AssertSqlSafe(sql)), params) {
                Ok(query) => query,
                Err(error) => {
                    return Err(transaction_failure(tx, idx, error).await);
                }
            };
            match q.execute(&mut *tx).await {
                Ok(res) if expect_one.contains(&idx) && res.rows_affected() != 1 => {
                    return Err(transaction_failure(tx, idx, DriverError::ConcurrentModification).await);
                }
                Ok(res) => affected.push(res.rows_affected()),
                Err(e) => {
                    return Err(transaction_failure(tx, idx, map_sqlx_error(e)).await);
                }
            }
        }
        tx.commit().await.map_err(map_sqlx_error)?;
        Ok(affected)
    }

    async fn fetch_indexes(&self, schema: Option<&str>, table: &str) -> Result<Vec<IndexInfo>, DriverError> {
        // information_schema.statistics returns one row per (index,
        // column). Group rows by index_name in Rust because sqlx can't
        // GROUP_CONCAT-then-split natively for ordered column lists.
        // PRIMARY is the literal index name MySQL uses for the PK.
        let rows = sqlx::query(
            "SELECT
                CAST(index_name AS CHAR) AS index_name,
                non_unique,
                CAST(column_name AS CHAR) AS column_name
            FROM information_schema.statistics
            WHERE table_schema = COALESCE(?, DATABASE())
              AND table_name = ?
            ORDER BY index_name, seq_in_index",
        )
        .bind(schema)
        .bind(table)
        .fetch_all(&self.pool)
        .await
        .map_err(map_sqlx_error)?;
        let mut by_name: std::collections::BTreeMap<String, IndexInfo> = std::collections::BTreeMap::new();
        for r in rows {
            let name: String = r.get(0);
            let non_unique: i64 = r.try_get(1).unwrap_or(0);
            let column: String = r.get(2);
            let entry = by_name.entry(name.clone()).or_insert_with(|| IndexInfo {
                name: name.clone(),
                columns: Vec::new(),
                unique: non_unique == 0,
                primary: name == "PRIMARY",
                predicate: None,
            });
            entry.columns.push(column);
        }
        Ok(by_name.into_values().collect())
    }

    async fn fetch_foreign_keys(&self, schema: Option<&str>, table: &str) -> Result<Vec<ForeignKeyInfo>, DriverError> {
        // key_column_usage gives us the FK column ↔ referenced column
        // pairs (one row per (constraint, ordinal)); referential_constraints
        // adds the ON DELETE / ON UPDATE rules. Group by constraint_name
        // in Rust to assemble the column lists.
        let rows = sqlx::query(
            "SELECT
                CAST(kcu.constraint_name AS CHAR),
                CAST(kcu.column_name AS CHAR),
                CAST(kcu.referenced_table_name AS CHAR),
                CAST(kcu.referenced_table_schema AS CHAR),
                CAST(kcu.referenced_column_name AS CHAR),
                CAST(rc.delete_rule AS CHAR),
                CAST(rc.update_rule AS CHAR)
            FROM information_schema.key_column_usage kcu
            JOIN information_schema.referential_constraints rc
                ON rc.constraint_name = kcu.constraint_name
                AND rc.constraint_schema = kcu.constraint_schema
            WHERE kcu.table_schema = COALESCE(?, DATABASE())
              AND kcu.table_name = ?
              AND kcu.referenced_table_name IS NOT NULL
            ORDER BY kcu.constraint_name, kcu.ordinal_position",
        )
        .bind(schema)
        .bind(table)
        .fetch_all(&self.pool)
        .await
        .map_err(map_sqlx_error)?;
        let mut by_name: std::collections::BTreeMap<String, ForeignKeyInfo> = std::collections::BTreeMap::new();
        for r in rows {
            let name: String = r.get(0);
            let column: String = r.get(1);
            let ref_table: String = r.get(2);
            let ref_schema: Option<String> = r.try_get(3).unwrap_or(None);
            let ref_column: String = r.get(4);
            let delete_rule: Option<String> = r.try_get(5).ok();
            let update_rule: Option<String> = r.try_get(6).ok();
            let entry = by_name.entry(name.clone()).or_insert_with(|| ForeignKeyInfo {
                name: name.clone(),
                columns: Vec::new(),
                ref_schema,
                ref_table,
                ref_columns: Vec::new(),
                on_delete: delete_rule.filter(|s| !s.is_empty() && s != "NO ACTION"),
                on_update: update_rule.filter(|s| !s.is_empty() && s != "NO ACTION"),
            });
            entry.columns.push(column);
            entry.ref_columns.push(ref_column);
        }
        Ok(by_name.into_values().collect())
    }

    async fn ping(&self) -> Result<(), DriverError> {
        sqlx::query("SELECT 1")
            .execute(&self.pool)
            .await
            .map_err(map_sqlx_error)?;
        Ok(())
    }

    async fn open_session(&self) -> Result<Box<dyn tablepro_core::Session>, DriverError> {
        session::open(&self.session_options, self.cancellation_pool.clone(), self.read_only).await
    }

    async fn begin(&self) -> Result<Box<dyn tablepro_core::Transaction>, DriverError> {
        let tx = self.pool.begin().await.map_err(map_sqlx_error)?;
        Ok(Box::new(MysqlTransaction { tx: Some(tx) }))
    }

    async fn server_version(&self) -> Result<Option<String>, DriverError> {
        let row = sqlx::query("SELECT VERSION()")
            .fetch_one(&self.pool)
            .await
            .map_err(map_sqlx_error)?;
        let v: String = row.try_get(0).unwrap_or_default();
        Ok(Some(v))
    }

    async fn close(self: Box<Self>) -> Result<(), DriverError> {
        self.pool.close().await;
        Ok(())
    }
}

fn validate_atomic_batch(statements: &[(String, Vec<Value>)]) -> Result<(), DriverError> {
    let dialect = MySqlDialect {};
    for (index, (sql, _)) in statements.iter().enumerate() {
        let parsed = Parser::parse_sql(&dialect, sql).map_err(|_| atomic_batch_refusal(index))?;
        let [statement] = parsed.as_slice() else {
            return Err(atomic_batch_refusal(index));
        };
        if !matches!(
            statement,
            SqlStatement::Insert(_) | SqlStatement::Update { .. } | SqlStatement::Delete(_)
        ) {
            return Err(atomic_batch_refusal(index));
        }
    }
    Ok(())
}

fn atomic_batch_refusal(statement_index: usize) -> DriverError {
    DriverError::Unsupported(format!(
        "statement {} cannot be guaranteed atomic on MySQL",
        statement_index + 1
    ))
}

async fn transaction_failure(
    tx: sqlx::Transaction<'static, MySql>,
    statement_index: usize,
    source: DriverError,
) -> DriverError {
    match tx.rollback().await {
        Ok(()) => DriverError::Transaction {
            statement_index,
            source: Box::new(source),
        },
        Err(error) => DriverError::TransactionRollbackFailed {
            statement_index,
            source: Box::new(source),
            rollback_error: Box::new(map_sqlx_error(error)),
        },
    }
}

struct MysqlTransaction {
    tx: Option<sqlx::Transaction<'static, MySql>>,
}

#[async_trait]
impl tablepro_core::Transaction for MysqlTransaction {
    async fn query(&mut self, sql: &str) -> Result<QueryResult, DriverError> {
        let tx = self
            .tx
            .as_mut()
            .ok_or_else(|| DriverError::Internal("transaction closed".into()))?;
        let timestamp_is_utc = timezone_is_utc(&mut **tx).await?;
        let mut result = params_into_result(tx, sql, &[], MAX_QUERY_ROWS).await?;
        if !timestamp_is_utc {
            refuse_non_utc_timestamps(&mut result);
        }
        Ok(result)
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

async fn set_utc_timezone(connection: &mut sqlx::MySqlConnection) -> Result<(), sqlx::Error> {
    sqlx::query("SET time_zone = '+00:00'").execute(connection).await?;
    Ok(())
}

async fn prepare_session(connection: &mut sqlx::MySqlConnection, read_only: bool) -> Result<(), sqlx::Error> {
    set_utc_timezone(connection).await?;
    if read_only {
        sqlx::query("SET SESSION TRANSACTION READ ONLY")
            .execute(connection)
            .await?;
    }
    Ok(())
}

async fn timezone_is_utc<'e, E>(executor: E) -> Result<bool, DriverError>
where
    E: sqlx::Executor<'e, Database = MySql>,
{
    let timezone: String = sqlx::query_scalar("SELECT @@session.time_zone")
        .fetch_one(executor)
        .await
        .map_err(map_sqlx_error)?;
    Ok(timezone == "+00:00")
}

fn refuse_non_utc_timestamps(result: &mut QueryResult) {
    for (column_index, column) in result.columns.iter().enumerate() {
        if column.data_type.eq_ignore_ascii_case("TIMESTAMP") {
            for row in &mut result.rows {
                if !matches!(row.get(column_index), Some(Value::Null)) {
                    row[column_index] = Value::Undecodable("TIMESTAMP (session time zone is not UTC)".into());
                }
            }
        }
    }
}

fn statement_columns(columns: &[sqlx::mysql::MySqlColumn]) -> Vec<ColumnInfo> {
    columns
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
        .collect()
}

fn extract_value(row: &MySqlRow, idx: usize) -> Value {
    let type_name = row.columns()[idx].type_info().name().to_ascii_uppercase();
    match row.try_get_raw(idx) {
        Ok(raw) if raw.is_null() => zero_calendar(raw, &type_name).unwrap_or(Value::Null),
        Ok(_) => decode_by_type(row, idx, &type_name).unwrap_or_else(|| undecodable(idx, &type_name)),
        Err(_) => undecodable(idx, &type_name),
    }
}

fn decode_by_type(row: &MySqlRow, idx: usize, type_name: &str) -> Option<Value> {
    match type_name {
        "TINYINT" | "SMALLINT" | "INT" | "MEDIUMINT" | "BIGINT" => row.try_get::<i64, _>(idx).map(Value::Int).ok(),
        // sqlx's i64 decoder refuses an UNSIGNED-flagged column
        // outright (a distinct type-compatibility class, not just the
        // same decode with a wider range), so every one of these
        // columns read back as an empty cell regardless of value --
        // decode as u64 instead, and keep BIGINT UNSIGNED's digits as
        // text on the rare value that exceeds i64::MAX.
        "TINYINT UNSIGNED" | "SMALLINT UNSIGNED" | "INT UNSIGNED" | "MEDIUMINT UNSIGNED" | "BIGINT UNSIGNED" => row
            .try_get::<u64, _>(idx)
            .map(|v| i64::try_from(v).map_or_else(|_| Value::Text(v.to_string()), Value::Int))
            .ok(),
        "FLOAT" | "DOUBLE" => row.try_get::<f64, _>(idx).map(Value::Float).ok(),
        // DECIMAL/NUMERIC arrive over the wire as text, but sqlx only
        // decodes that text into rust_decimal::Decimal, which caps out
        // at ~28-29 significant digits -- well inside what MySQL
        // itself allows (up to 65). A legitimately large value keeps
        // its exact digits as text instead of the row's real number
        // silently disappearing.
        "DECIMAL" | "NUMERIC" => decode_decimal_exact(row, idx),
        "BOOLEAN" => row.try_get::<bool, _>(idx).map(Value::Bool).ok(),
        "DATE" => row
            .try_get::<chrono::NaiveDate, _>(idx)
            .map(Value::Date)
            .ok()
            .or_else(|| temporal::calendar_text(row.try_get_raw(idx).ok()?, false)),
        "TIME" => temporal::time_value(row.try_get_raw(idx).ok()?),
        "DATETIME" => row
            .try_get::<chrono::NaiveDateTime, _>(idx)
            .map(Value::DateTime)
            .ok()
            .or_else(|| temporal::calendar_text(row.try_get_raw(idx).ok()?, true)),
        "YEAR" => temporal::year_value(row.try_get_raw(idx).ok()?),
        "BIT" => packed::bit_value(row.try_get_raw(idx).ok()?),
        "GEOMETRY" => packed::geometry_value(row.try_get_raw(idx).ok()?),
        "ENUM" | "SET" => row
            .try_get::<String, _>(idx)
            .map(Value::Text)
            .or_else(|_| row.try_get::<Vec<u8>, _>(idx).map(Value::Bytes))
            .ok(),
        "TIMESTAMP" => row
            .try_get::<chrono::DateTime<chrono::Utc>, _>(idx)
            .map(Value::TimestampTz)
            .ok(),
        "JSON" => row.try_get::<serde_json::Value, _>(idx).map(Value::Json).ok(),
        "BLOB" | "TINYBLOB" | "MEDIUMBLOB" | "LONGBLOB" | "VARBINARY" | "BINARY" => {
            row.try_get::<Vec<u8>, _>(idx).map(Value::Bytes).ok()
        }
        _ => row.try_get::<String, _>(idx).map(Value::Text).ok(),
    }
}

fn zero_calendar(raw: sqlx::mysql::MySqlValueRef<'_>, type_name: &str) -> Option<Value> {
    match type_name {
        "DATE" => temporal::calendar_text(raw, false),
        "DATETIME" | "TIMESTAMP" => temporal::calendar_text(raw, true),
        _ => None,
    }
}

fn undecodable(idx: usize, type_name: &str) -> Value {
    tracing::warn!(
        column_index = idx + 1,
        type_name,
        "mysql column value could not be decoded; showing it as undecodable"
    );
    Value::Undecodable(type_name.to_string())
}

/// `String`'s `Type<MySql>` compatibility check refuses a DECIMAL
/// column outright, even though its wire representation is already
/// text -- decoding through the raw value ref bypasses that check
/// instead of going through `Row::try_get`.
fn decode_decimal_exact(row: &MySqlRow, idx: usize) -> Option<Value> {
    let raw = row.try_get_raw(idx).ok()?;
    if raw.is_null() {
        return None;
    }
    <&str as sqlx::Decode<sqlx::MySql>>::decode(raw)
        .map(|text| {
            rust_decimal::Decimal::from_str_exact(text)
                .map(Value::Decimal)
                .unwrap_or_else(|_| Value::Text(text.to_owned()))
        })
        .ok()
}

async fn params_into_result(
    connection: &mut sqlx::MySqlConnection,
    sql: &str,
    params: &[Value],
    limit: usize,
) -> Result<QueryResult, DriverError> {
    let statement = connection
        .prepare(sqlx::AssertSqlSafe(sql).into_sql_str())
        .await
        .map_err(map_sqlx_error)?;
    let columns = statement_columns(statement.columns());
    let query = bind_mysql_params(sqlx::query(sqlx::AssertSqlSafe(sql)), params)?;
    let mut stream = query.fetch(&mut *connection);
    let mut rows = Vec::with_capacity(limit.min(1024));
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
    Ok(QueryResult {
        columns,
        rows,
        truncated,
    })
}

async fn execute_on<'e, E>(executor: E, sql: &str, params: &[Value]) -> Result<ExecResult, DriverError>
where
    E: sqlx::Executor<'e, Database = MySql>,
{
    let query = bind_mysql_params(sqlx::query(sqlx::AssertSqlSafe(sql)), params)?;
    let result = query.execute(executor).await.map_err(map_sqlx_error)?;
    Ok(ExecResult {
        rows_affected: result.rows_affected(),
    })
}

async fn acquire_controlled(
    pool: &Pool<MySql>,
    control: &OperationControl,
) -> Result<PoolConnection<MySql>, DriverError> {
    check_pre_dispatch(control)?;
    run_controlled_setup(pool.acquire(), control)
        .await?
        .map_err(map_sqlx_error)
}

async fn connection_id_controlled(
    connection: &mut PoolConnection<MySql>,
    control: &OperationControl,
) -> Result<u64, DriverError> {
    run_controlled_setup(connection_id(connection), control).await?
}

async fn connection_id(connection: &mut PoolConnection<MySql>) -> Result<u64, DriverError> {
    sqlx::query_scalar("SELECT CONNECTION_ID()")
        .fetch_one(&mut **connection)
        .await
        .map_err(map_sqlx_error)
}

/// MySQL has no request-scoped cancel channel, so the statement is
/// stopped by `KILL QUERY` from a second session. That aborts the
/// running statement and leaves the session alive, which is what makes
/// the connection reusable afterwards.
///
/// `run_server_cancellable` wraps this future in its own dispatch
/// timeout and moves on without it if that elapses. The KILL QUERY
/// round trip runs in a spawned task instead of inline so giving up on
/// it here can never drop it mid-response and return a
/// protocol-desynced connection to the single-slot cancellation pool --
/// the task always finishes and explicitly closes the connection on
/// failure rather than trusting an implicit pool return.
async fn request_cancellation(pool: &Pool<MySql>, connection_id: u64) -> Result<(), DriverError> {
    let pool = pool.clone();
    let task = tokio::spawn(async move {
        let mut conn = pool.acquire().await.map_err(map_sqlx_error)?;
        let outcome = sqlx::query(sqlx::AssertSqlSafe(format!("KILL QUERY {connection_id}")))
            .execute(&mut *conn)
            .await
            .map_err(map_sqlx_error);
        if outcome.is_err() {
            let _ = conn.detach().close_hard().await;
        }
        outcome.map(|_| ())
    });
    match task.await {
        Ok(result) => result,
        Err(_) => Err(DriverError::Cancelled),
    }
}

/// `ER_QUERY_INTERRUPTED` is the only outcome that proves the server
/// aborted the statement rather than the client giving up on it.
fn confirms_cancellation(error: &DriverError) -> bool {
    matches!(
        error,
        DriverError::Query {
            sqlstate: Some(sqlstate),
            ..
        } if sqlstate == "70100"
    )
}

async fn release_connection<T>(connection: PoolConnection<MySql>, result: &Result<T, DriverError>) {
    if matches!(result, Err(DriverError::OperationOutcomeUnknown { .. })) {
        let _ = connection.detach().close_hard().await;
    }
}

fn bind_mysql_params<'q>(
    mut q: sqlx::query::Query<'q, MySql, sqlx::mysql::MySqlArguments>,
    params: &'q [Value],
) -> Result<sqlx::query::Query<'q, MySql, sqlx::mysql::MySqlArguments>, DriverError> {
    for p in params {
        q = match p {
            Value::Null => q.bind(Option::<&str>::None),
            Value::Bool(b) => q.bind(*b),
            Value::Int(i) => q.bind(*i),
            Value::Float(f) => q.bind(*f),
            Value::Text(s) => q.bind(s.clone()),
            Value::Bytes(b) => q.bind(b.clone()),
            Value::Date(d) => q.bind(*d),
            Value::Time(t) => q.bind(*t),
            Value::DateTime(dt) => q.bind(*dt),
            Value::TimestampTz(ts) => q.bind(*ts),
            Value::Decimal(d) => q.bind(*d),
            Value::Uuid(u) => q.bind(u.to_string()),
            Value::Json(j) => q.bind(j.clone()),
            Value::Undecodable(_) => {
                return Err(DriverError::Unsupported(
                    "undecodable cell cannot be bound as a parameter".into(),
                ));
            }
        };
    }
    Ok(q)
}

/// Dial through the SSH-forwarded socket when there is one, keeping the real
/// service hostname as the TLS identity sqlx verifies against; otherwise
/// dial and verify the same TCP host, exactly as an untunnelled connection
/// already did.
fn mysql_connect_options(opts: &ConnectOptions) -> MySqlConnectOptions {
    use tablepro_core::TlsMode;
    let mut mysql_opts = match opts.transport() {
        Transport::Tcp { host, port } => MySqlConnectOptions::new().host(host).port(port),
        Transport::Socket {
            directory,
            identity_host,
            identity_port,
            ..
        } => MySqlConnectOptions::new()
            .host(identity_host)
            .port(identity_port)
            .socket(directory.join(FORWARDED_SOCKET_NAME)),
    };
    mysql_opts = mysql_opts
        .database(&opts.database)
        .username(&opts.username)
        .password(opts.password.expose_secret())
        .ssl_mode(match opts.tls.mode {
            TlsMode::Disabled => sqlx::mysql::MySqlSslMode::Disabled,
            TlsMode::Prefer => sqlx::mysql::MySqlSslMode::Preferred,
            TlsMode::Require => sqlx::mysql::MySqlSslMode::Required,
            TlsMode::VerifyCa => sqlx::mysql::MySqlSslMode::VerifyCa,
            TlsMode::VerifyFull => sqlx::mysql::MySqlSslMode::VerifyIdentity,
        });
    if let Some(path) = &opts.tls.root_cert {
        mysql_opts = mysql_opts.ssl_ca(path);
    }
    if let Some(path) = &opts.tls.client_cert {
        mysql_opts = mysql_opts.ssl_client_cert(path);
    }
    if let Some(path) = &opts.tls.client_key {
        mysql_opts = mysql_opts.ssl_client_key(path);
    }
    mysql_opts
}

fn quote_ident(name: &str) -> String {
    format!("`{}`", name.replace('`', "``"))
}

fn qualified(schema: Option<&str>, table: &str) -> String {
    match schema {
        Some(s) => format!("{}.{}", quote_ident(s), quote_ident(table)),
        None => quote_ident(table),
    }
}

const UNQUOTED_DEFAULT_TYPE_PREFIXES: [&str; 12] = [
    "tinyint",
    "smallint",
    "mediumint",
    "int",
    "bigint",
    "decimal",
    "numeric",
    "float",
    "double",
    "real",
    "bit",
    "year",
];

// MySQL reports a literal default in information_schema.column_default as
// its bare value (`pending`, an empty string for ''), which is not a valid
// DEFAULT clause. MySQL 8 flags an expression default with
// DEFAULT_GENERATED in `extra`; 5.7 reports CURRENT_TIMESTAMP bare on a
// temporal column. Anything else on a non-numeric column is a string
// literal and is quoted back so restating the column keeps its default.
// MariaDB 10.2.7+ already reports the DEFAULT clause itself and reports a
// column without a default as the text NULL.
fn default_expression(raw: Option<String>, column_type: &str, extra: &str, mariadb: bool) -> Option<String> {
    let raw = raw?;
    if mariadb {
        return (!raw.eq_ignore_ascii_case("null")).then_some(raw);
    }
    let lower_type = column_type.to_ascii_lowercase();
    let numeric = UNQUOTED_DEFAULT_TYPE_PREFIXES
        .iter()
        .any(|prefix| lower_type.starts_with(prefix));
    let temporal_now = (lower_type.starts_with("timestamp") || lower_type.starts_with("datetime"))
        && raw.to_ascii_lowercase().starts_with("current_timestamp");
    if numeric || temporal_now || extra.contains("default_generated") {
        return Some(raw);
    }
    tablepro_core::sql_literal::render_sql_literal("mysql", &Value::Text(raw)).ok()
}

fn row_to_column_info(r: &MySqlRow) -> ColumnInfo {
    let extra = r.try_get::<String, _>(4).unwrap_or_default().to_ascii_lowercase();
    let column_type = r.get::<String, _>(1);
    let mariadb = r.try_get::<i64, _>(9).unwrap_or(0) == 1;
    let default_value = default_expression(
        r.try_get::<Option<String>, _>(5).unwrap_or(None),
        &column_type,
        &extra,
        mariadb,
    );
    let generation_expr: Option<String> = r.try_get::<Option<String>, _>(6).unwrap_or(None);
    ColumnInfo {
        name: r.get::<String, _>(0),
        data_type: column_type,
        nullable: r.get::<String, _>(2) == "YES",
        primary_key: r.get::<String, _>(3) == "PRI",
        is_auto_increment: extra.contains("auto_increment"),
        default_value,
        // Two false-positives to guard against:
        //   1. MySQL 8.0.13+ marks expression-default columns
        //      (e.g. DEFAULT CURRENT_TIMESTAMP) with extra =
        //      "DEFAULT_GENERATED" — contains "generated" but
        //      not a generated column. Match the explicit
        //      keywords instead.
        //   2. information_schema.generation_expression returns
        //      an *empty string* for non-generated columns,
        //      not NULL — so `generation_expr.is_some()` is
        //      true even for plain columns. Check non-empty.
        is_generated: generation_expr.as_deref().is_some_and(|s| !s.is_empty())
            || extra.contains("virtual generated")
            || extra.contains("stored generated"),
        // information_schema.column_comment is an empty
        // string, never NULL, for a column with no comment.
        comment: r
            .try_get::<Option<String>, _>(7)
            .unwrap_or(None)
            .filter(|s| !s.is_empty()),
        collation: r
            .try_get::<Option<String>, _>(8)
            .unwrap_or(None)
            .filter(|c| !c.is_empty()),
        enum_type: None,
        domain_type: None,
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
        Io(e) if tablepro_core::looks_like_tls_failure(&tablepro_core::error_chain_text(&e)) => {
            DriverError::Tls(tablepro_core::error_chain_text(&e))
        }
        Io(_) => DriverError::Disconnected,
        Tls(e) => DriverError::Tls(e.to_string()),
        PoolClosed | PoolTimedOut => DriverError::Disconnected,
        other => DriverError::Internal(format!("{other}")),
    }
}

fn map_sqlx_connect_error(err: sqlx::Error) -> DriverError {
    if is_pool_startup_timeout(&err) {
        // SQLx retries refused pool connections until the acquire deadline,
        // then erases the underlying I/O error into PoolTimedOut. During
        // initial setup there is no established connection to disconnect.
        DriverError::ConnectionRefused
    } else {
        map_sqlx_error(err)
    }
}

fn is_pool_startup_timeout(err: &sqlx::Error) -> bool {
    matches!(err, sqlx::Error::PoolTimedOut)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn undecodable_cell_cannot_be_bound_as_null() {
        let params = [Value::Undecodable("GEOMETRY".into())];
        assert!(matches!(
            bind_mysql_params(sqlx::query(sqlx::AssertSqlSafe("SELECT ?")), &params),
            Err(DriverError::Unsupported(_))
        ));
    }

    #[test]
    fn unexpected_io_eof_is_reported_as_disconnected() {
        let error = sqlx::Error::Io(std::io::Error::new(
            std::io::ErrorKind::UnexpectedEof,
            "server closed the connection",
        ));
        assert!(matches!(map_sqlx_error(error), DriverError::Disconnected));
    }

    #[test]
    fn a_tls_certificate_failure_wrapped_in_io_remains_a_tls_error() {
        #[derive(Debug)]
        struct CertificateNameMismatch;

        impl std::fmt::Display for CertificateNameMismatch {
            fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
                f.write_str("invalid peer certificate: NotValidForName")
            }
        }

        impl std::error::Error for CertificateNameMismatch {}

        #[derive(Debug)]
        struct ClosedTlsHandshake(CertificateNameMismatch);

        impl std::fmt::Display for ClosedTlsHandshake {
            fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
                f.write_str("connection closed unexpectedly")
            }
        }

        impl std::error::Error for ClosedTlsHandshake {
            fn source(&self) -> Option<&(dyn std::error::Error + 'static)> {
                Some(&self.0)
            }
        }

        let error = sqlx::Error::Io(std::io::Error::new(
            std::io::ErrorKind::InvalidData,
            ClosedTlsHandshake(CertificateNameMismatch),
        ));
        assert!(matches!(map_sqlx_error(error), DriverError::Tls(message) if message.contains("certificate")));
    }

    #[test]
    fn connection_refusal_remains_distinct_from_disconnection() {
        let error = sqlx::Error::Io(std::io::Error::new(
            std::io::ErrorKind::ConnectionRefused,
            "connection refused",
        ));
        assert!(matches!(map_sqlx_error(error), DriverError::ConnectionRefused));
    }

    #[test]
    fn structure_metadata_declarations_match_the_connection_impl() {
        let d = MysqlDriver;
        let source = include_str!("lib.rs");
        assert!(d.supports_index_metadata());
        assert!(d.supports_foreign_key_metadata());
        assert!(source.contains(&["async fn ", "fetch_indexes("].concat()));
        assert!(source.contains(&["async fn ", "fetch_foreign_keys("].concat()));
    }

    #[test]
    fn driver_metadata() {
        let d = MysqlDriver;
        assert_eq!(d.id(), "mysql");
        assert_eq!(d.display_name(), "MySQL");
        assert_eq!(d.default_port(), 3306);
        assert_eq!(d.default_database(), "mysql");
        assert_eq!(d.default_username(), "root");
        assert!(d.supports_client_tls_auth());
    }

    #[test]
    fn map_io_refused_returns_connection_refused() {
        let err = sqlx::Error::Io(std::io::Error::from(std::io::ErrorKind::ConnectionRefused));
        assert!(matches!(map_sqlx_error(err), DriverError::ConnectionRefused));
    }

    #[test]
    fn a_pool_startup_timeout_is_not_mapped_as_an_established_disconnect() {
        assert!(matches!(
            map_sqlx_connect_error(sqlx::Error::PoolTimedOut),
            DriverError::ConnectionRefused
        ));
        assert!(matches!(
            map_sqlx_error(sqlx::Error::PoolTimedOut),
            DriverError::Disconnected
        ));
        assert!(matches!(
            map_sqlx_connect_error(sqlx::Error::PoolClosed),
            DriverError::Disconnected
        ));
    }

    #[test]
    fn quote_ident_doubles_embedded_backticks() {
        assert_eq!(quote_ident("users"), "`users`");
        assert_eq!(quote_ident("My Table"), "`My Table`");
        assert_eq!(quote_ident("evil`; DROP TABLE x; --"), "`evil``; DROP TABLE x; --`");
    }

    #[test]
    fn a_direct_connection_dials_and_verifies_the_same_host() {
        let opts = ConnectOptions {
            host: "db.corp.example".into(),
            port: 3306,
            ..Default::default()
        };
        let mysql_opts = mysql_connect_options(&opts);
        assert_eq!(mysql_opts.get_host(), "db.corp.example");
        assert_eq!(mysql_opts.get_socket(), None);
    }

    /// H1: a tunnelled connection must dial the forwarded local socket but
    /// keep verifying TLS against the real service hostname, not 127.0.0.1
    /// -- exactly the pattern PostgreSQL's driver already uses.
    #[test]
    fn a_tunnelled_connection_dials_the_forwarded_socket_and_verifies_the_service_hostname() {
        let directory = std::path::PathBuf::from("/tmp/tablepro-ssh-abc123");
        let opts = ConnectOptions {
            host: "127.0.0.1".into(),
            port: 54321,
            service_endpoint: Some(("db.corp.example".into(), 3306)),
            forwarded_socket_dir: Some(directory.clone()),
            ..Default::default()
        };
        let mysql_opts = mysql_connect_options(&opts);
        assert_eq!(mysql_opts.get_host(), "db.corp.example");
        assert_eq!(mysql_opts.get_port(), 3306);
        assert_eq!(mysql_opts.get_socket(), Some(&directory.join(FORWARDED_SOCKET_NAME)));
    }
}
