use std::time::Duration;

use async_trait::async_trait;
use secrecy::ExposeSecret;
use sqlx::mysql::{MySql, MySqlConnectOptions, MySqlPoolOptions, MySqlRow};
use sqlx::{AssertSqlSafe, Column, Pool, Row, TypeInfo};

use futures::stream::StreamExt;

use tablepro_core::column::{
    CatalogType, ColumnDefault, ColumnType, ReadForm, ResultColumn, SqlExpression, SqlTypeExpr, classify_type_name,
    has_dynamic_storage,
};
use tablepro_core::value::{BitString, JsonText, OffsetTimestamp, SqlTime, Temporal};
use tablepro_core::{
    ColumnInfo, ConnectOptions, Connection, DatabaseDriver, DriverError, ExecResult, ForeignKeyInfo, IndexInfo,
    LossPhase, MAX_QUERY_ROWS, NetworkEndpoint, QueryResult, ReadOnlyRefusal, ServerCode, ServerDiagnostics, TableInfo,
    TimeoutPhase, TlsFailure, TransportError, Value,
};

pub struct MysqlDriver;

#[async_trait]
impl DatabaseDriver for MysqlDriver {
    fn id(&self) -> &'static str {
        "mysql"
    }

    fn display_name(&self) -> &'static str {
        "MySQL"
    }

    fn default_port(&self) -> u16 {
        3306
    }

    async fn connect(&self, opts: ConnectOptions) -> Result<Box<dyn Connection>, DriverError> {
        let mysql_opts = MySqlConnectOptions::new()
            .host(&opts.host)
            .port(opts.port)
            .database(&opts.database)
            .username(&opts.username)
            .password(opts.password.expose_secret())
            .ssl_mode(if opts.use_tls {
                sqlx::mysql::MySqlSslMode::Required
            } else {
                sqlx::mysql::MySqlSslMode::Disabled
            });
        let endpoint = NetworkEndpoint::new(&opts.host, opts.port)?;
        let pool = MySqlPoolOptions::new()
            .max_connections(4)
            .acquire_timeout(Duration::from_secs(5))
            .connect_with(mysql_opts)
            .await
            .map_err(|error| map_connect_error(error, &endpoint))?;
        Ok(Box::new(MysqlConnection { pool }))
    }
}

struct MysqlConnection {
    pool: Pool<MySql>,
}

#[async_trait]
impl Connection for MysqlConnection {
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
                    CAST(generation_expression AS CHAR), CAST(column_comment AS CHAR)
             FROM information_schema.columns
             WHERE table_schema = COALESCE(?, DATABASE()) AND table_name = ?
             ORDER BY ordinal_position",
        )
        .bind(schema)
        .bind(table)
        .fetch_all(&self.pool)
        .await
        .map_err(map_sqlx_error)?;
        Ok(rows
            .into_iter()
            .map(|r| {
                let extra = r.try_get::<String, _>(4).unwrap_or_default().to_ascii_lowercase();
                // information_schema.column_default uses NULL for "no
                // default", but some sqlx + MySQL combinations surface
                // it as an empty string. Treat empty as absent so the
                // build_insert_from_draft "omit when default present"
                // heuristic doesn't trigger on phantom defaults.
                let default_value: Option<String> = r
                    .try_get::<Option<String>, _>(5)
                    .unwrap_or(None)
                    .filter(|s| !s.is_empty());
                let generation_expr: Option<String> = r.try_get::<Option<String>, _>(6).unwrap_or(None);
                // MySQL has no "no comment": a column without one
                // carries the empty string, so that is what absent
                // looks like here.
                let comment = r
                    .try_get::<Option<String>, _>(7)
                    .unwrap_or(None)
                    .filter(|text| !text.is_empty());
                let type_name = r.get::<String, _>(1);
                ColumnInfo {
                    name: r.get::<String, _>(0),
                    column_type: column_type_of(&type_name),
                    nullable: r.get::<String, _>(2) == "YES",
                    primary_key: r.get::<String, _>(3) == "PRI",
                    is_auto_increment: extra.contains("auto_increment"),
                    default: match default_value {
                        Some(text) => ColumnDefault::Expression(SqlExpression::from_catalog_text(text)),
                        None => ColumnDefault::None,
                    },
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
                    comment,
                }
            })
            .collect())
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
        stream_into_result(&self.pool, &sql, limit as usize).await
    }

    async fn query(&self, sql: &str) -> Result<QueryResult, DriverError> {
        stream_into_result(&self.pool, sql, MAX_QUERY_ROWS).await
    }

    async fn query_params(&self, sql: &str, params: &[Value]) -> Result<QueryResult, DriverError> {
        let q = bind_mysql_params(sqlx::query(AssertSqlSafe(sql)), params);
        let mut stream = q.fetch(&self.pool);
        let mut collected: Vec<MySqlRow> = Vec::new();
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
        let q = bind_mysql_params(sqlx::query(AssertSqlSafe(sql)), params);
        let res = q.execute(&self.pool).await.map_err(map_sqlx_error)?;
        Ok(ExecResult {
            rows_affected: res.rows_affected(),
        })
    }

    async fn execute_in_transaction(&self, statements: &[(String, Vec<Value>)]) -> Result<Vec<u64>, DriverError> {
        let mut tx = self.pool.begin().await.map_err(map_sqlx_error)?;
        let mut affected = Vec::with_capacity(statements.len());
        for (idx, (sql, params)) in statements.iter().enumerate() {
            let q = bind_mysql_params(sqlx::query(AssertSqlSafe(sql.as_str())), params);
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

    async fn close(self: Box<Self>) -> Result<(), DriverError> {
        self.pool.close().await;
        Ok(())
    }
}

async fn stream_into_result(pool: &Pool<MySql>, sql: &str, limit: usize) -> Result<QueryResult, DriverError> {
    let mut stream = sqlx::query(AssertSqlSafe(sql)).fetch(pool);
    let mut collected: Vec<MySqlRow> = Vec::new();
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

fn extract_value(row: &MySqlRow, idx: usize) -> Value {
    let type_name = row.columns()[idx].type_info().name().to_ascii_uppercase();
    let name = type_name.as_str();
    match name {
        "BOOLEAN" => decode(row, idx, name, |v: bool| Some(Value::Bool(v))),
        "TINYINT" | "SMALLINT" | "INT" | "MEDIUMINT" | "BIGINT" => decode(row, idx, name, |v: i64| Some(Value::Int(v))),
        // An unsigned BIGINT runs past what a signed one holds, so it
        // keeps its own type rather than wrapping into a negative.
        "TINYINT UNSIGNED" | "SMALLINT UNSIGNED" | "INT UNSIGNED" | "MEDIUMINT UNSIGNED" | "BIGINT UNSIGNED"
        | "YEAR" => decode(row, idx, name, |v: u64| Some(Value::UInt(v))),
        "FLOAT" => decode(row, idx, name, |v: f32| Some(Value::Float32(v))),
        "DOUBLE" => decode(row, idx, name, |v: f64| Some(Value::Float64(v))),
        // DECIMAL travels as text in both protocols, so it is read as
        // the digits the server sent: a fixed-width decimal type would
        // round a DECIMAL(65,30) the server holds exactly.
        "DECIMAL" => decode_text(row, idx, name, |text| text.parse().ok().map(Value::Decimal)),
        "DATE" => decode(row, idx, name, |v: chrono::NaiveDate| {
            Some(Value::Date(Temporal::Finite(v)))
        }),
        "TIME" => decode(row, idx, name, mysql_time),
        "DATETIME" => decode(row, idx, name, |v: chrono::NaiveDateTime| {
            Some(Value::Timestamp(Temporal::Finite(v)))
        }),
        "TIMESTAMP" => decode(row, idx, name, |v: chrono::DateTime<chrono::Utc>| {
            Some(Value::TimestampTz(Temporal::Finite(OffsetTimestamp::from_datetime(
                v.fixed_offset(),
            ))))
        }),
        // Read as the server rendered it: parsing the document and
        // printing it again would reorder the keys and drop spacing.
        "JSON" => decode_text(row, idx, name, |text| {
            JsonText::parse(text.to_owned()).ok().map(Value::Json)
        }),
        // BIT(M) arrives as the ceil(M/8) bytes that hold it, with no
        // count of its own, so the byte width is what the value keeps.
        "BIT" => decode_bytes(row, idx, name, |bytes| {
            let bit_len = u32::try_from(bytes.len().saturating_mul(8)).ok()?;
            BitString::from_bytes(bit_len, bytes).ok().map(Value::Bits)
        }),
        "BLOB" | "TINYBLOB" | "MEDIUMBLOB" | "LONGBLOB" | "VARBINARY" | "BINARY" | "GEOMETRY" => {
            decode(row, idx, name, |v: Vec<u8>| Some(Value::Bytes(v)))
        }
        _ => decode(row, idx, name, |v: String| Some(Value::Text(v))),
    }
}

/// Read one cell, keeping three outcomes apart: a real NULL, a value
/// the driver read, and one it could not read. A type with no decoder
/// says so rather than reading as an empty cell the user would take
/// for a NULL.
fn decode<'r, T, F>(row: &'r MySqlRow, idx: usize, type_name: &str, into_value: F) -> Value
where
    T: sqlx::Decode<'r, MySql> + sqlx::Type<MySql>,
    F: FnOnce(T) -> Option<Value>,
{
    match row.try_get::<Option<T>, _>(idx) {
        Ok(Some(raw)) => into_value(raw).unwrap_or_else(|| undecodable(type_name)),
        Ok(None) => Value::Null,
        Err(_) => undecodable(type_name),
    }
}

/// Read a cell whose bytes are text the server already formatted, such
/// as DECIMAL and JSON. The type check is skipped because those types
/// carry text without being text types.
fn decode_text<F>(row: &MySqlRow, idx: usize, type_name: &str, into_value: F) -> Value
where
    F: FnOnce(&str) -> Option<Value>,
{
    match row.try_get_unchecked::<Option<String>, _>(idx) {
        Ok(Some(text)) => into_value(&text).unwrap_or_else(|| undecodable(type_name)),
        Ok(None) => Value::Null,
        Err(_) => undecodable(type_name),
    }
}

/// Read a cell as the bytes the server sent, for a type the byte
/// width itself carries meaning for.
fn decode_bytes<F>(row: &MySqlRow, idx: usize, type_name: &str, into_value: F) -> Value
where
    F: FnOnce(Vec<u8>) -> Option<Value>,
{
    match row.try_get_unchecked::<Option<Vec<u8>>, _>(idx) {
        Ok(Some(bytes)) => into_value(bytes).unwrap_or_else(|| undecodable(type_name)),
        Ok(None) => Value::Null,
        Err(_) => undecodable(type_name),
    }
}

/// A value the driver could not read, so the grid says so rather than
/// showing an empty cell that looks like a NULL.
fn undecodable(type_name: &str) -> Value {
    Value::Undecodable(Box::new(tablepro_core::value::UndecodedValue {
        type_name: type_name.to_owned(),
        reason: tablepro_core::value::UndecodableReason::UnsupportedType,
    }))
}

/// A MySQL TIME spans -838:59:59 to 838:59:59, which is a span rather
/// than a time of day, so it keeps a type that holds the whole range.
fn mysql_time(time: sqlx::mysql::types::MySqlTime) -> Option<Value> {
    let nanos = time.microseconds().checked_mul(1_000)?;
    // The sign comes from `sign()`: `MySqlTime::is_negative` in sqlx
    // 0.9 returns `sign.is_positive()`, so it answers backwards.
    let negative = matches!(time.sign(), sqlx::mysql::types::MySqlTimeSign::Negative);
    SqlTime::new(negative, time.hours(), time.minutes(), time.seconds(), nanos)
        .ok()
        .map(Value::Time)
}

fn bind_mysql_params<'q>(
    mut q: sqlx::query::Query<'q, MySql, sqlx::mysql::MySqlArguments>,
    params: &'q [Value],
) -> sqlx::query::Query<'q, MySql, sqlx::mysql::MySqlArguments> {
    for p in params {
        q = match p {
            Value::Null => q.bind(Option::<&str>::None),
            Value::Bool(b) => q.bind(*b),
            Value::Int(i) => q.bind(*i),
            Value::UInt(i) => q.bind(*i),
            Value::Float32(f) => q.bind(*f),
            Value::Float64(f) => q.bind(*f),
            Value::Text(s) => q.bind(s.clone()),
            Value::Bytes(b) => q.bind(b.clone()),
            Value::Date(Temporal::Finite(d)) => q.bind(*d),
            Value::Timestamp(Temporal::Finite(t)) => q.bind(*t),
            Value::TimestampTz(Temporal::Finite(t)) => q.bind(t.to_datetime().naive_utc()),
            Value::Uuid(u) => q.bind(u.to_string()),
            // Sent as text and cast by the server, which keeps the
            // scale a fixed-width decimal type would round away.
            other => match tablepro_core::export::value_to_text(other) {
                Some(text) => q.bind(text),
                None => q.bind(Option::<&str>::None),
            },
        };
    }
    q
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

/// A failure during connect, where an unreachable server is the
/// answer rather than a connection that was lost.
fn map_connect_error(err: sqlx::Error, endpoint: &NetworkEndpoint) -> DriverError {
    match err {
        sqlx::Error::Io(io) => DriverError::Transport(connect_transport_error(&io, endpoint)),
        sqlx::Error::PoolTimedOut => DriverError::Transport(TransportError::Timeout {
            phase: TimeoutPhase::Connect,
        }),
        other => map_sqlx_error(other),
    }
}

fn connect_transport_error(io: &std::io::Error, endpoint: &NetworkEndpoint) -> TransportError {
    match io.kind() {
        std::io::ErrorKind::ConnectionRefused => TransportError::Refused {
            endpoint: endpoint.clone(),
        },
        std::io::ErrorKind::TimedOut => TransportError::Timeout {
            phase: TimeoutPhase::Connect,
        },
        _ => TransportError::Unreachable {
            endpoint: endpoint.clone(),
            detail: io.to_string(),
        },
    }
}

fn map_sqlx_error(err: sqlx::Error) -> DriverError {
    match err {
        sqlx::Error::Database(error) => match error.try_downcast_ref::<sqlx::mysql::MySqlDatabaseError>() {
            Some(mysql) => server_error(mysql),
            None => DriverError::server(error.message().to_owned()),
        },
        // An I/O failure on an open connection is the connection going
        // away, whatever the kind says.
        sqlx::Error::Io(_) => DriverError::ConnectionLost {
            during: LossPhase::Statement,
        },
        sqlx::Error::Tls(error) => tls_error(error.as_ref()),
        // The pool's wait ends only when every connection is busy, so
        // it is the server having no room rather than a slow network.
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

/// The error numbers that mean something the app acts on. MariaDB
/// numbers a few of them differently, so both are listed.
fn server_error(mysql: &sqlx::mysql::MySqlDatabaseError) -> DriverError {
    let diagnostics = diagnostics_of(mysql);
    match mysql.number() {
        1045 => DriverError::auth(Some(diagnostics)),
        1290 | 1792 => DriverError::ReadOnly(ReadOnlyRefusal::server(diagnostics)),
        1317 => DriverError::Cancelled,
        1205 => DriverError::Timeout {
            phase: TimeoutPhase::LockWait,
            server_cancelled: true,
        },
        // 3024 on MySQL, 1969 on MariaDB.
        3024 | 1969 => DriverError::Timeout {
            phase: TimeoutPhase::Statement,
            server_cancelled: true,
        },
        1040 => DriverError::Busy,
        _ => DriverError::reported(diagnostics),
    }
}

fn diagnostics_of(mysql: &sqlx::mysql::MySqlDatabaseError) -> ServerDiagnostics {
    ServerDiagnostics::new(
        Some(ServerCode::MySql {
            number: mysql.number(),
            sqlstate: mysql.code().map(str::to_owned),
        }),
        mysql.message().to_owned(),
    )
}

fn tls_error(error: &(dyn std::error::Error + 'static)) -> DriverError {
    let (failure, detail) =
        tablepro_net::tls::classify(error).unwrap_or_else(|| (TlsFailure::Other, error.to_string()));
    DriverError::Tls { failure, detail }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn driver_metadata() {
        let d = MysqlDriver;
        assert_eq!(d.id(), "mysql");
        assert_eq!(d.display_name(), "MySQL");
        assert_eq!(d.default_port(), 3306);
    }

    #[test]
    fn a_refused_connect_names_the_endpoint_it_tried() {
        let endpoint = NetworkEndpoint::new("db.internal", 3306).expect("an endpoint");
        let err = sqlx::Error::Io(std::io::Error::from(std::io::ErrorKind::ConnectionRefused));

        let mapped = map_connect_error(err, &endpoint);

        assert!(
            matches!(&mapped, DriverError::Transport(TransportError::Refused { endpoint: at }) if at == &endpoint),
            "got {mapped:?}"
        );
    }

    #[test]
    fn a_dropped_connection_mid_statement_is_not_a_refusal() {
        let err = sqlx::Error::Io(std::io::Error::from(std::io::ErrorKind::BrokenPipe));

        assert!(matches!(
            map_sqlx_error(err),
            DriverError::ConnectionLost {
                during: LossPhase::Statement
            }
        ));
    }

    #[test]
    fn quote_ident_doubles_embedded_backticks() {
        assert_eq!(quote_ident("users"), "`users`");
        assert_eq!(quote_ident("My Table"), "`My Table`");
        assert_eq!(quote_ident("evil`; DROP TABLE x; --"), "`evil``; DROP TABLE x; --`");
    }
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

/// MySQL TIME is a signed duration up to 838 hours, not a time of day,
/// so it is parsed into a value that can hold the whole range.
#[cfg(test)]
mod value_tests {
    use super::*;

    use sqlx::mysql::types::{MySqlTime, MySqlTimeSign};

    fn wire_time(sign: MySqlTimeSign, hours: u32, minutes: u8, seconds: u8, micros: u32) -> MySqlTime {
        MySqlTime::new(sign, hours, minutes, seconds, micros).expect("a time the wire holds")
    }

    #[test]
    fn a_time_past_a_day_is_kept_whole() {
        // The server can return 838:59:59, which is not a time of day
        // and would be lost by a type that only holds one.
        let Some(Value::Time(time)) = mysql_time(wire_time(MySqlTimeSign::Positive, 838, 59, 59, 0)) else {
            panic!("the longest MySQL time did not convert");
        };

        assert_eq!(time.format(None), "838:59:59");
    }

    #[test]
    fn a_negative_time_keeps_its_sign() {
        let Some(Value::Time(time)) = mysql_time(wire_time(MySqlTimeSign::Negative, 12, 30, 0, 0)) else {
            panic!("a negative time did not convert");
        };

        assert_eq!(time.format(None), "-12:30:00");
    }

    #[test]
    fn a_fractional_second_survives() {
        let Some(Value::Time(time)) = mysql_time(wire_time(MySqlTimeSign::Positive, 1, 2, 3, 123_456)) else {
            panic!("a fractional time did not convert");
        };

        assert_eq!(time.format(Some(6)), "01:02:03.123456");
    }
}
