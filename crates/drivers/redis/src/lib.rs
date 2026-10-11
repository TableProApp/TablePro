use std::time::Duration;

use async_trait::async_trait;
use redis::aio::ConnectionManager;
use redis::{AsyncCommands, Client, RedisError, TlsCertificates, Value as RedisValue};
use secrecy::ExposeSecret;
use tokio::sync::Mutex;

use tablepro_core::{
    ColumnInfo, ConnectOptions, Connection, DatabaseDriver, DriverError, DriverMaturity, ExecResult,
    MAX_QUERY_RESULT_BYTES, MAX_QUERY_ROWS, QueryResult, QueryResultBudget, TableInfo, Value, error_chain_text,
    looks_like_tls_failure,
};

mod value;

pub struct RedisDriver;

#[async_trait]
impl DatabaseDriver for RedisDriver {
    fn id(&self) -> &'static str {
        "redis"
    }

    fn display_name(&self) -> &'static str {
        "Redis"
    }

    fn maturity(&self) -> DriverMaturity {
        DriverMaturity::Experimental
    }

    fn default_port(&self) -> u16 {
        6379
    }

    fn default_database(&self) -> &'static str {
        "0"
    }

    fn default_username(&self) -> &'static str {
        "default"
    }

    async fn connect(&self, opts: ConnectOptions) -> Result<Box<dyn Connection>, DriverError> {
        let scheme = match opts.tls.mode {
            tablepro_core::TlsMode::Disabled => "redis",
            _ => "rediss",
        };
        let password = opts.password.expose_secret();
        let auth = if !opts.username.is_empty() && !password.is_empty() {
            format!("{}:{}@", urlencoding_lite(&opts.username), urlencoding_lite(password))
        } else if !password.is_empty() {
            format!(":{}@", urlencoding_lite(password))
        } else {
            String::new()
        };
        let db_index = parse_db_index(&opts.database)?;
        let verifies = opts.tls.mode.verifies_cert();
        let suffix = if opts.tls.mode.encrypts() && !verifies {
            "#insecure"
        } else {
            ""
        };
        let url = format!("{scheme}://{auth}{}:{}/{}{suffix}", opts.host, opts.port, db_index);
        let client = if opts.tls.mode.encrypts() {
            Client::build_with_tls(url, tls_certificates_for(&opts, verifies)?)
                .map_err(|err| map_redis_connect_error(err, verifies))?
        } else {
            Client::open(url).map_err(|err| map_redis_connect_error(err, verifies))?
        };
        let manager = match tokio::time::timeout(CONNECT_TIMEOUT, establish_connection_manager(client.clone())).await {
            Ok(result) => result.map_err(|err| map_redis_connect_error(err, verifies))?,
            Err(_) => return Err(DriverError::ConnectionRefused),
        };
        Ok(Box::new(RedisConnection {
            conn: Mutex::new(manager),
            db_count: 16,
            browse_client: client,
        }))
    }
}

const CONNECT_TIMEOUT: Duration = Duration::from_secs(5);

/// Builds the TLS certificates the client dials with. `verify_host` pins
/// certificate verification to the database's own hostname rather than
/// `opts.host`, which can be an SSH tunnel's `127.0.0.1`.
fn tls_certificates_for(opts: &ConnectOptions, verifies: bool) -> Result<TlsCertificates, DriverError> {
    Ok(TlsCertificates {
        client_tls: None,
        root_cert: root_certificate(&opts.tls, verifies)?,
        verify_host: verifies.then(|| opts.service_address().0.to_string()),
    })
}

/// Read the certificate authority the connection names. Only a verifying mode
/// consults it, so an encrypt-only session never fails on a path it ignores.
fn root_certificate(config: &tablepro_core::TlsConfig, verifies: bool) -> Result<Option<Vec<u8>>, DriverError> {
    if !verifies {
        return Ok(None);
    }
    let Some(path) = &config.root_cert else {
        return Ok(None);
    };
    std::fs::read(path).map(Some).map_err(|error| {
        DriverError::Tls(format!(
            "cannot read the certificate authority at {}: {error}",
            path.display()
        ))
    })
}

struct RedisConnection {
    conn: Mutex<ConnectionManager>,
    db_count: usize,
    // Never clone the normal ConnectionManager for browsing: clones share SELECT state.
    browse_client: Client,
}

fn redis_columns() -> Vec<ColumnInfo> {
    vec![
        ColumnInfo {
            name: "Key".into(),
            data_type: "string".into(),
            nullable: false,
            primary_key: true,
            is_auto_increment: false,
            default_value: None,
            is_generated: false,
            comment: None,
            collation: None,
            enum_type: None,
            domain_type: None,
        },
        ColumnInfo {
            name: "Type".into(),
            data_type: "string".into(),
            nullable: false,
            primary_key: false,
            is_auto_increment: false,
            default_value: None,
            is_generated: false,
            comment: None,
            collation: None,
            enum_type: None,
            domain_type: None,
        },
        ColumnInfo {
            name: "TTL".into(),
            data_type: "integer".into(),
            nullable: false,
            primary_key: false,
            is_auto_increment: false,
            default_value: None,
            is_generated: false,
            comment: None,
            collation: None,
            enum_type: None,
            domain_type: None,
        },
        ColumnInfo {
            name: "Value".into(),
            data_type: "string".into(),
            nullable: true,
            primary_key: false,
            is_auto_increment: false,
            default_value: None,
            is_generated: false,
            comment: None,
            collation: None,
            enum_type: None,
            domain_type: None,
        },
    ]
}

#[async_trait]
impl Connection for RedisConnection {
    async fn list_tables(&self) -> Result<Vec<TableInfo>, DriverError> {
        let mut conn = self.conn.lock().await;
        let count = match redis::cmd("CONFIG")
            .arg("GET")
            .arg("databases")
            .query_async::<Vec<String>>(&mut *conn)
            .await
        {
            Ok(pairs) => pairs
                .get(1)
                .and_then(|s| s.parse::<usize>().ok())
                .unwrap_or(self.db_count),
            Err(_) => self.db_count,
        };
        Ok((0..count)
            .map(|i| TableInfo {
                schema: None,
                name: format!("db{i}"),
            })
            .collect())
    }

    async fn fetch_columns(&self, _schema: Option<&str>, _table: &str) -> Result<Vec<ColumnInfo>, DriverError> {
        Ok(redis_columns())
    }

    async fn fetch_rows(
        &self,
        _schema: Option<&str>,
        table: &str,
        offset: u64,
        limit: u64,
    ) -> Result<QueryResult, DriverError> {
        let db = parse_db_name(table)?;
        let mut conn = value::browse_connection(self, db).await?;
        fetch_page(&mut conn, offset, limit).await
    }

    async fn query_params(&self, sql: &str, params: &[Value]) -> Result<QueryResult, DriverError> {
        if params.is_empty() {
            return self.query(sql).await;
        }
        let Some(query) = value::parse_value_query(sql, params) else {
            return Err(DriverError::Unsupported(
                "Redis bound reads support the Value column for one key".into(),
            ));
        };
        value::fetch_string_value(self, query).await
    }

    async fn query(&self, sql: &str) -> Result<QueryResult, DriverError> {
        let trimmed = sql.trim();
        if trimmed.is_empty() {
            return Ok(QueryResult {
                columns: Vec::new(),
                rows: Vec::new(),
                truncated: false,
            });
        }
        let mut conn = self.conn.lock().await;
        let args = split_redis_cli(trimmed);
        if args.is_empty() {
            return Err(DriverError::query("empty Redis command"));
        }
        if is_redis_stream_command(&args) {
            return Err(DriverError::Unsupported(
                "Redis Pub/Sub, MONITOR, and client tracking streams are not supported by the request/response query interface".into(),
            ));
        }
        let mut cmd = redis::cmd(&args[0]);
        for arg in &args[1..] {
            cmd.arg(arg);
        }
        let value: RedisValue = cmd.query_async(&mut *conn).await.map_err(map_redis_error)?;
        Ok(redis_value_to_result(value))
    }

    async fn execute(&self, sql: &str) -> Result<ExecResult, DriverError> {
        let result = self.query(sql).await?;
        Ok(ExecResult {
            rows_affected: result.rows.len() as u64,
        })
    }

    async fn execute_params(&self, sql: &str, params: &[Value]) -> Result<ExecResult, DriverError> {
        if params.is_empty() {
            return self.execute(sql).await;
        }
        Err(DriverError::Unsupported(
            "Redis execute_params does not support bound parameters".into(),
        ))
    }

    async fn execute_in_transaction(&self, statements: &[(String, Vec<Value>)]) -> Result<Vec<u64>, DriverError> {
        let mut affected = Vec::with_capacity(statements.len());
        for (idx, (sql, params)) in statements.iter().enumerate() {
            match self.execute_params(sql, params).await {
                Ok(res) => affected.push(res.rows_affected),
                Err(e) => {
                    return Err(DriverError::Transaction {
                        statement_index: idx,
                        source: Box::new(e),
                    });
                }
            }
        }
        Ok(affected)
    }

    async fn ping(&self) -> Result<(), DriverError> {
        let mut conn = self.conn.lock().await;
        redis::cmd("PING")
            .query_async::<String>(&mut *conn)
            .await
            .map_err(map_redis_error)?;
        Ok(())
    }

    async fn server_version(&self) -> Result<Option<String>, DriverError> {
        let mut conn = self.conn.lock().await;
        let info: String = redis::cmd("INFO")
            .arg("server")
            .query_async(&mut *conn)
            .await
            .map_err(map_redis_error)?;
        let version = info
            .lines()
            .find_map(|line| line.strip_prefix("redis_version:").map(str::trim).map(str::to_string));
        Ok(version.map(|v| format!("Redis {v}")))
    }

    async fn close(self: Box<Self>) -> Result<(), DriverError> {
        Ok(())
    }
}

async fn fetch_page(
    conn: &mut redis::aio::MultiplexedConnection,
    offset: u64,
    limit: u64,
) -> Result<QueryResult, DriverError> {
    let keys = scan_keys(conn, "*", (offset + limit) as usize).await?;
    let skip = offset as usize;
    let page: Vec<Vec<u8>> = keys.into_iter().skip(skip).take(limit as usize).collect();
    let mut rows = Vec::with_capacity(page.len());
    for key in page {
        rows.push(key_row(conn, &key).await?);
    }
    Ok(QueryResult {
        columns: redis_columns(),
        rows,
        truncated: false,
    })
}

async fn scan_keys(
    conn: &mut redis::aio::MultiplexedConnection,
    pattern: &str,
    limit: usize,
) -> Result<Vec<Vec<u8>>, DriverError> {
    let mut cursor: u64 = 0;
    let mut keys = Vec::new();
    loop {
        let (next, batch): (u64, Vec<Vec<u8>>) = redis::cmd("SCAN")
            .arg(cursor)
            .arg("MATCH")
            .arg(pattern)
            .arg("COUNT")
            .arg(100)
            .query_async(conn)
            .await
            .map_err(map_redis_error)?;
        keys.extend(batch);
        cursor = next;
        if cursor == 0 || keys.len() >= limit {
            break;
        }
    }
    keys.truncate(limit);
    Ok(keys)
}

async fn key_row(conn: &mut redis::aio::MultiplexedConnection, key: &[u8]) -> Result<Vec<Value>, DriverError> {
    let key_type: String = conn.key_type(key).await.map_err(map_redis_error)?;
    let ttl: i64 = conn.ttl(key).await.map_err(map_redis_error)?;
    let preview = match key_type.as_str() {
        "string" => {
            let v: Vec<u8> = conn.get(key).await.map_err(map_redis_error)?;
            bytes_to_value(v)
        }
        "hash" => {
            let v: Vec<(String, String)> = conn.hgetall(key).await.map_err(map_redis_error)?;
            Value::Text(format!("{v:?}"))
        }
        "list" => {
            let v: Vec<String> = conn.lrange(key, 0, 20).await.map_err(map_redis_error)?;
            Value::Text(format!("{v:?}"))
        }
        "set" => {
            let v: Vec<String> = conn.smembers(key).await.map_err(map_redis_error)?;
            Value::Text(format!("{v:?}"))
        }
        "zset" => {
            let v: Vec<String> = conn.zrange(key, 0, 20).await.map_err(map_redis_error)?;
            Value::Text(format!("{v:?}"))
        }
        other => Value::Text(format!("<{other}>")),
    };
    Ok(vec![
        bytes_to_value(key.to_vec()),
        Value::Text(key_type),
        Value::Int(ttl),
        preview,
    ])
}

fn redis_value_to_result(value: RedisValue) -> QueryResult {
    match value {
        RedisValue::Nil => QueryResult {
            columns: vec![text_col("result")],
            rows: vec![vec![Value::Null]],
            truncated: false,
        },
        RedisValue::Okay => QueryResult {
            columns: vec![text_col("result")],
            rows: vec![vec![Value::Text("OK".into())]],
            truncated: false,
        },
        RedisValue::SimpleString(s) => QueryResult {
            columns: vec![text_col("result")],
            rows: vec![vec![Value::Text(s)]],
            truncated: false,
        },
        RedisValue::Int(i) => QueryResult {
            columns: vec![ColumnInfo {
                name: "result".into(),
                data_type: "integer".into(),
                nullable: false,
                primary_key: false,
                is_auto_increment: false,
                default_value: None,
                is_generated: false,
                comment: None,
                collation: None,
                enum_type: None,
                domain_type: None,
            }],
            rows: vec![vec![Value::Int(i)]],
            truncated: false,
        },
        RedisValue::Double(f) => QueryResult {
            columns: vec![ColumnInfo {
                name: "result".into(),
                data_type: "double".into(),
                nullable: false,
                primary_key: false,
                is_auto_increment: false,
                default_value: None,
                is_generated: false,
                comment: None,
                collation: None,
                enum_type: None,
                domain_type: None,
            }],
            rows: vec![vec![Value::Float(f)]],
            truncated: false,
        },
        RedisValue::Boolean(b) => QueryResult {
            columns: vec![ColumnInfo {
                name: "result".into(),
                data_type: "boolean".into(),
                nullable: false,
                primary_key: false,
                is_auto_increment: false,
                default_value: None,
                is_generated: false,
                comment: None,
                collation: None,
                enum_type: None,
                domain_type: None,
            }],
            rows: vec![vec![Value::Bool(b)]],
            truncated: false,
        },
        RedisValue::BulkString(bytes) => QueryResult {
            columns: vec![text_col("result")],
            rows: vec![vec![bytes_to_value(bytes)]],
            truncated: false,
        },
        RedisValue::Array(items) | RedisValue::Set(items) => {
            let mut rows = Vec::new();
            let mut budget = QueryResultBudget::default();
            let mut truncated = false;
            for item in items {
                if rows.len() >= MAX_QUERY_ROWS {
                    truncated = true;
                    break;
                }
                let row = vec![redis_scalar(item)];
                if !budget.admit(&row) {
                    truncated = true;
                    break;
                }
                rows.push(row);
            }
            QueryResult {
                columns: vec![text_col("value")],
                rows,
                truncated,
            }
        }
        RedisValue::Map(pairs) => {
            let mut rows = Vec::new();
            let mut budget = QueryResultBudget::default();
            let mut truncated = false;
            for (key, value) in pairs {
                let row = vec![redis_scalar(key), redis_scalar(value)];
                if !budget.admit(&row) {
                    truncated = true;
                    break;
                }
                rows.push(row);
            }
            QueryResult {
                columns: vec![text_col("key"), text_col("value")],
                rows,
                truncated,
            }
        }
        RedisValue::VerbatimString { text, .. } => QueryResult {
            columns: vec![text_col("result")],
            rows: vec![vec![Value::Text(text)]],
            truncated: false,
        },
        other => QueryResult {
            columns: vec![text_col("result")],
            rows: vec![vec![redis_scalar(other)]],
            truncated: false,
        },
    }
}

fn is_redis_stream_command(args: &[String]) -> bool {
    let Some(command) = args.first() else {
        return false;
    };
    if matches!(
        command.to_ascii_uppercase().as_str(),
        "SUBSCRIBE" | "PSUBSCRIBE" | "SSUBSCRIBE" | "UNSUBSCRIBE" | "PUNSUBSCRIBE" | "SUNSUBSCRIBE" | "MONITOR"
    ) {
        return true;
    }
    command.eq_ignore_ascii_case("CLIENT")
        && args.get(1).is_some_and(|arg| arg.eq_ignore_ascii_case("TRACKING"))
        && args.get(2).is_some_and(|arg| arg.eq_ignore_ascii_case("ON"))
}

fn text_col(name: &str) -> ColumnInfo {
    ColumnInfo {
        name: name.into(),
        data_type: "string".into(),
        nullable: true,
        primary_key: false,
        is_auto_increment: false,
        default_value: None,
        is_generated: false,
        comment: None,
        collation: None,
        enum_type: None,
        domain_type: None,
    }
}

fn redis_scalar(value: RedisValue) -> Value {
    match value {
        RedisValue::Nil => Value::Null,
        RedisValue::Int(i) => Value::Int(i),
        RedisValue::Double(f) => Value::Float(f),
        RedisValue::Boolean(b) => Value::Bool(b),
        RedisValue::SimpleString(s) => Value::Text(s),
        RedisValue::BulkString(b) => bytes_to_value(b),
        RedisValue::Okay => Value::Text("OK".into()),
        RedisValue::VerbatimString { text, .. } => Value::Text(text),
        RedisValue::Array(_)
        | RedisValue::Map(_)
        | RedisValue::Set(_)
        | RedisValue::Attribute { .. }
        | RedisValue::Push { .. }
        | RedisValue::ServerError(_) => Value::Json(redis_value_to_json(value)),
        RedisValue::BigNumber(value) => Value::Text(value.to_string()),
        _ => Value::Undecodable("unknown Redis reply kind".into()),
    }
}

fn redis_value_to_json(value: RedisValue) -> serde_json::Value {
    match value {
        RedisValue::Nil => serde_json::Value::Null,
        RedisValue::Int(value) => serde_json::json!(value),
        RedisValue::Double(value) => serde_json::Number::from_f64(value)
            .map(serde_json::Value::Number)
            .unwrap_or_else(|| serde_json::json!({"$redisDouble": value.to_string()})),
        RedisValue::Boolean(value) => serde_json::json!(value),
        RedisValue::SimpleString(value) => serde_json::json!(value),
        RedisValue::Okay => serde_json::json!("OK"),
        RedisValue::BulkString(bytes) => bytes_to_json(bytes),
        RedisValue::Array(items) => serde_json::Value::Array(items.into_iter().map(redis_value_to_json).collect()),
        RedisValue::Set(items) => serde_json::json!({
            "$redisSet": items.into_iter().map(redis_value_to_json).collect::<Vec<_>>()
        }),
        RedisValue::Map(pairs) => serde_json::json!({
            "$redisMap": pairs
                .into_iter()
                .map(|(key, value)| [redis_value_to_json(key), redis_value_to_json(value)])
                .collect::<Vec<_>>()
        }),
        RedisValue::Attribute { data, attributes } => serde_json::json!({
            "$redisAttribute": {
                "data": redis_value_to_json(*data),
                "attributes": attributes
                    .into_iter()
                    .map(|(key, value)| [redis_value_to_json(key), redis_value_to_json(value)])
                    .collect::<Vec<_>>()
            }
        }),
        RedisValue::VerbatimString { format, text } => serde_json::json!({
            "$redisVerbatim": {"format": format!("{format:?}"), "text": text}
        }),
        RedisValue::BigNumber(value) => serde_json::json!({"$redisBigNumber": value.to_string()}),
        RedisValue::Push { kind, data } => serde_json::json!({
            "$redisPush": {
                "kind": format!("{kind:?}"),
                "data": data.into_iter().map(redis_value_to_json).collect::<Vec<_>>()
            }
        }),
        RedisValue::ServerError(error) => serde_json::json!({"$redisServerError": error.to_string()}),
        _ => serde_json::json!({"$redisUnsupportedReply": "unknown RESP value kind"}),
    }
}

fn bytes_to_json(bytes: Vec<u8>) -> serde_json::Value {
    match String::from_utf8(bytes) {
        Ok(text) => serde_json::json!(text),
        Err(error) => {
            let hex = error
                .into_bytes()
                .iter()
                .map(|byte| format!("{byte:02x}"))
                .collect::<String>();
            serde_json::json!({"$redisBytes": hex})
        }
    }
}

fn bytes_to_value(bytes: Vec<u8>) -> Value {
    match String::from_utf8(bytes) {
        Ok(text) => Value::Text(text),
        Err(error) => Value::Bytes(error.into_bytes()),
    }
}

fn parse_db_name(table: &str) -> Result<u8, DriverError> {
    let stripped = table.strip_prefix("db").unwrap_or(table);
    stripped
        .parse::<u8>()
        .map_err(|_| DriverError::query(format!("invalid Redis database name: {table}")))
}

/// Minimal Redis CLI tokenizer: splits on whitespace, respects double quotes.
pub fn split_redis_cli(input: &str) -> Vec<String> {
    let mut out = Vec::new();
    let mut cur = String::new();
    let mut in_quotes = false;
    let mut token_started = false;
    let mut chars = input.chars().peekable();
    while let Some(c) = chars.next() {
        match c {
            '"' => {
                in_quotes = !in_quotes;
                token_started = true;
            }
            '\\' if in_quotes => {
                if let Some(next) = chars.next() {
                    cur.push(next);
                    token_started = true;
                }
            }
            c if c.is_whitespace() && !in_quotes => {
                if token_started {
                    out.push(std::mem::take(&mut cur));
                    token_started = false;
                }
            }
            _ => {
                cur.push(c);
                token_started = true;
            }
        }
    }
    if token_started {
        out.push(cur);
    }
    out
}

/// An empty database means "use Redis's default (0)". Anything else must be
/// a plain non-negative integer -- `"12 "`, `"db3"` and similar previously
/// fell back to db 0 silently, which is usually the production database.
fn parse_db_index(database: &str) -> Result<u8, DriverError> {
    let trimmed = database.trim();
    if trimmed.is_empty() {
        return Ok(0);
    }
    trimmed
        .parse::<u8>()
        .map_err(|_| DriverError::Unsupported(format!("'{database}' is not a valid Redis database index")))
}

fn urlencoding_lite(s: &str) -> String {
    let mut out = String::with_capacity(s.len());
    for b in s.bytes() {
        match b {
            b'A'..=b'Z' | b'a'..=b'z' | b'0'..=b'9' | b'-' | b'_' | b'.' | b'~' => out.push(b as char),
            _ => out.push_str(&format!("%{b:02X}")),
        }
    }
    out
}

async fn establish_connection_manager(client: Client) -> Result<ConnectionManager, RedisError> {
    client.get_multiplexed_async_connection().await?;
    ConnectionManager::new(client).await
}

fn redis_error_can_hide_tls(err: &RedisError) -> bool {
    matches!(err.kind(), redis::ErrorKind::Io | redis::ErrorKind::Client)
        || err.is_connection_refusal()
        || err.is_connection_dropped()
        || err.is_timeout()
}

fn map_redis_error(err: RedisError) -> DriverError {
    map_redis_error_in_context(err, false, false)
}

fn map_redis_connect_error(err: RedisError, verifies_cert: bool) -> DriverError {
    map_redis_error_in_context(err, true, verifies_cert)
}

fn map_redis_error_in_context(err: RedisError, connecting: bool, verifies_cert: bool) -> DriverError {
    let chain = error_chain_text(&err);
    if redis_error_can_hide_tls(&err) && looks_like_tls_failure(&chain) {
        return DriverError::Tls(chain);
    }
    let msg = err.to_string();
    if msg.contains("Connection refused") || err.is_connection_refusal() {
        if connecting {
            DriverError::ConnectionRefused
        } else {
            DriverError::Disconnected
        }
    } else if msg.contains("NOAUTH") || msg.contains("WRONGPASS") || msg.contains("invalid password") {
        DriverError::AuthFailed
    } else if verifies_cert && err.is_connection_dropped() {
        DriverError::Tls("certificate hostname mismatch; connection closed during TLS verification".into())
    } else if err.kind() == redis::ErrorKind::Io {
        if connecting {
            DriverError::ConnectionRefused
        } else {
            DriverError::Disconnected
        }
    } else {
        DriverError::query(msg)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[tokio::test]
    async fn open_session_is_refused() {
        let client = Client::open("redis://127.0.0.1:6379/0").unwrap();
        let manager =
            ConnectionManager::new_lazy_with_config(client.clone(), redis::aio::ConnectionManagerConfig::default())
                .unwrap();
        let conn = RedisConnection {
            conn: Mutex::new(manager),
            db_count: 16,
            browse_client: client,
        };

        match conn.open_session().await {
            Err(DriverError::Unsupported(_)) => {}
            Ok(_) => panic!("redis must refuse open_session"),
            Err(other) => panic!("expected Unsupported, got {other:?}"),
        }
    }

    #[test]
    fn a_tunneled_connection_verifies_tls_against_the_service_hostname() {
        let opts = ConnectOptions {
            host: "127.0.0.1".into(),
            port: 6380,
            service_endpoint: Some(("cache.internal.example".into(), 6379)),
            tls: tablepro_core::TlsConfig {
                mode: tablepro_core::TlsMode::VerifyFull,
                ..Default::default()
            },
            ..Default::default()
        };

        let certificates = tls_certificates_for(&opts, true).expect("build TLS certificates");

        assert_eq!(certificates.verify_host.as_deref(), Some("cache.internal.example"));
    }

    #[test]
    fn an_encrypt_only_connection_does_not_verify_a_hostname() {
        let opts = ConnectOptions {
            host: "127.0.0.1".into(),
            port: 6380,
            service_endpoint: Some(("cache.internal.example".into(), 6379)),
            tls: tablepro_core::TlsConfig {
                mode: tablepro_core::TlsMode::Require,
                ..Default::default()
            },
            ..Default::default()
        };

        let certificates = tls_certificates_for(&opts, false).expect("build TLS certificates");

        assert_eq!(certificates.verify_host, None);
    }

    #[test]
    fn value_contract_empty_quoted_arguments_are_not_dropped() {
        assert_eq!(split_redis_cli(r#"SET key """#), vec!["SET", "key", ""]);
        assert_eq!(
            split_redis_cli(r#"MSET "" "" key "" "#),
            vec!["MSET", "", "", "key", ""]
        );
    }

    #[test]
    fn structure_metadata_is_not_declared_without_a_fetch() {
        let d = RedisDriver;
        let source = include_str!("lib.rs");
        assert!(!d.supports_index_metadata());
        assert!(!d.supports_foreign_key_metadata());
        assert!(!source.contains(&["async fn ", "fetch_indexes("].concat()));
        assert!(!source.contains(&["async fn ", "fetch_foreign_keys("].concat()));
    }

    #[test]
    fn an_empty_database_defaults_to_zero() {
        assert_eq!(parse_db_index("").unwrap(), 0);
        assert_eq!(parse_db_index("   ").unwrap(), 0);
    }

    #[test]
    fn a_valid_index_is_used_even_with_surrounding_whitespace() {
        assert_eq!(parse_db_index("12").unwrap(), 12);
        assert_eq!(parse_db_index(" 12 ").unwrap(), 12);
    }

    /// A typo or stray text must refuse the connection, not silently land
    /// on db 0 -- usually the production database.
    #[test]
    fn a_malformed_database_index_is_refused_instead_of_defaulting_to_zero() {
        for bad in ["db3", "16abc", "-1", "1.5"] {
            assert!(parse_db_index(bad).is_err(), "{bad}");
        }
    }

    #[test]
    fn driver_metadata() {
        let d = RedisDriver;
        assert_eq!(d.id(), "redis");
        assert_eq!(d.display_name(), "Redis");
        assert_eq!(d.default_port(), 6379);
        assert_eq!(d.default_database(), "0");
        assert_eq!(d.default_username(), "default");
    }

    #[test]
    fn split_redis_cli_handles_quotes() {
        assert_eq!(split_redis_cli("GET foo"), vec!["GET", "foo"]);
        assert_eq!(
            split_redis_cli(r#"SET key "hello world""#),
            vec!["SET", "key", "hello world"]
        );
        assert_eq!(split_redis_cli(r#"SET k "a\"b""#), vec!["SET", "k", "a\"b"]);
    }

    #[test]
    fn split_redis_cli_keeps_a_backslash_literal_outside_quotes() {
        assert_eq!(split_redis_cli(r"SET k a\b"), vec!["SET", "k", r"a\b"]);
    }

    #[test]
    fn parse_db_name_accepts_db_n() {
        assert_eq!(parse_db_name("db0").unwrap(), 0);
        assert_eq!(parse_db_name("db15").unwrap(), 15);
        assert!(parse_db_name("users").is_err());
    }

    #[test]
    fn urlencoding_lite_keeps_unreserved_characters_and_encodes_everything_else() {
        assert_eq!(urlencoding_lite("Az09-_.~"), "Az09-_.~");
        assert_eq!(urlencoding_lite("a b"), "a%20b");
        assert_eq!(urlencoding_lite("p@ss/w:rd"), "p%40ss%2Fw%3Ard");
    }

    #[test]
    fn map_redis_error_classifies_connection_refusal_during_operation_as_disconnected() {
        let err = RedisError::from(std::io::Error::from(std::io::ErrorKind::ConnectionRefused));
        assert!(matches!(map_redis_error(err), DriverError::Disconnected));
    }

    #[test]
    fn a_non_timeout_io_error_during_an_operation_is_disconnected() {
        let err = RedisError::from(std::io::Error::new(
            std::io::ErrorKind::PermissionDenied,
            "socket transport failed",
        ));
        assert!(matches!(map_redis_error(err), DriverError::Disconnected));
    }

    #[test]
    fn a_plain_connection_refused_stays_connection_refused_when_verifying() {
        let err = RedisError::from(std::io::Error::from(std::io::ErrorKind::ConnectionRefused));
        assert!(matches!(
            map_redis_connect_error(err, true),
            DriverError::ConnectionRefused
        ));
    }

    #[test]
    fn setup_time_socket_reset_and_broken_pipe_are_connection_refused() {
        for kind in [std::io::ErrorKind::ConnectionReset, std::io::ErrorKind::BrokenPipe] {
            let err = RedisError::from(std::io::Error::from(kind));
            assert!(
                matches!(map_redis_connect_error(err, false), DriverError::ConnectionRefused),
                "setup-time {kind:?} must stay distinct from established disconnection"
            );
        }
    }

    #[test]
    fn a_certificate_name_mismatch_io_error_maps_to_tls() {
        let err = RedisError::from(std::io::Error::other(
            "invalid peer certificate: certificate not valid for name \"127.0.0.1\"",
        ));
        assert!(matches!(map_redis_error(err), DriverError::Tls(detail) if detail.contains("certificate")));
    }

    #[test]
    fn a_connection_refused_carrying_a_name_mismatch_maps_to_tls() {
        let err = RedisError::from(std::io::Error::new(
            std::io::ErrorKind::ConnectionRefused,
            "invalid peer certificate: certificate not valid for name \"127.0.0.1\"",
        ));
        let mapped = map_redis_connect_error(err, true);
        assert!(matches!(mapped, DriverError::Tls(detail) if detail.contains("certificate")));
    }

    #[test]
    fn verifying_connect_does_not_report_a_hostname_mismatch_as_a_refusal() {
        let err = RedisError::from(std::io::Error::new(
            std::io::ErrorKind::ConnectionRefused,
            "invalid peer certificate: NotValidForName",
        ));
        let mapped = map_redis_connect_error(err, true);
        assert!(matches!(
            mapped,
            DriverError::Tls(detail)
                if detail.to_ascii_lowercase().contains("certificate")
                    || detail.to_ascii_lowercase().contains("notvalidforname")
        ));
    }

    #[test]
    fn rustls_invalid_data_name_mismatch_maps_to_tls() {
        let err = RedisError::from(std::io::Error::new(
            std::io::ErrorKind::InvalidData,
            "invalid peer certificate: NotValidForName",
        ));
        let mapped = map_redis_connect_error(err, true);
        assert!(matches!(
            mapped,
            DriverError::Tls(detail) if detail.to_ascii_lowercase().contains("notvalidforname")
        ));
    }

    #[test]
    fn verifying_connect_maps_a_dropped_handshake_without_tls_text() {
        let err = RedisError::from(std::io::Error::from(std::io::ErrorKind::ConnectionReset));
        assert!(matches!(map_redis_error(err.clone()), DriverError::Disconnected));
        let mapped = map_redis_connect_error(err, true);
        assert!(
            matches!(mapped, DriverError::Tls(detail) if detail.contains("certificate") && detail.contains("hostname"))
        );
    }

    #[test]
    fn looks_like_tls_failure_reads_rustls_identity_text() {
        assert!(looks_like_tls_failure(
            "invalid peer certificate: certificate not valid for name \"127.0.0.1\""
        ));
        assert!(looks_like_tls_failure("invalid peer certificate: NotValidForName"));
        assert!(!looks_like_tls_failure("Connection refused"));
    }

    #[test]
    fn map_redis_error_recognizes_noauth_and_wrongpass_as_auth_failures() {
        let noauth = RedisError::from((
            redis::ErrorKind::AuthenticationFailed,
            "authentication required",
            "NOAUTH Authentication required.".to_string(),
        ));
        assert!(matches!(map_redis_error(noauth), DriverError::AuthFailed));

        let wrongpass = RedisError::from((
            redis::ErrorKind::AuthenticationFailed,
            "authentication failed",
            "WRONGPASS invalid username-password pair".to_string(),
        ));
        assert!(matches!(map_redis_error(wrongpass), DriverError::AuthFailed));
    }

    #[test]
    fn map_redis_error_falls_back_to_a_query_error() {
        let err = RedisError::from((redis::ErrorKind::UnexpectedReturnType, "unexpected type"));
        assert!(matches!(map_redis_error(err), DriverError::Query { .. }));
    }

    #[test]
    fn redis_value_to_result_maps_nil_okay_and_scalars() {
        assert_eq!(redis_value_to_result(RedisValue::Nil).rows, vec![vec![Value::Null]]);
        assert_eq!(
            redis_value_to_result(RedisValue::Okay).rows,
            vec![vec![Value::Text("OK".into())]]
        );
        assert_eq!(
            redis_value_to_result(RedisValue::Int(42)).rows,
            vec![vec![Value::Int(42)]]
        );
        assert_eq!(
            redis_value_to_result(RedisValue::Boolean(true)).rows,
            vec![vec![Value::Bool(true)]]
        );
    }

    #[test]
    fn redis_value_to_result_decodes_valid_utf8_binary_as_text() {
        let result = redis_value_to_result(RedisValue::BulkString(b"hello".to_vec()));
        assert_eq!(result.rows, vec![vec![Value::Text("hello".into())]]);
    }

    #[test]
    fn redis_value_to_result_preserves_invalid_utf8_binary() {
        let result = redis_value_to_result(RedisValue::BulkString(vec![0xFF, 0xFE]));
        assert_eq!(result.rows, vec![vec![Value::Bytes(vec![0xFF, 0xFE])]]);
    }

    #[test]
    fn redis_value_to_result_maps_an_array_to_one_row_per_item() {
        let result = redis_value_to_result(RedisValue::Array(vec![
            RedisValue::Int(1),
            RedisValue::SimpleString("two".into()),
        ]));
        assert_eq!(result.rows, vec![vec![Value::Int(1)], vec![Value::Text("two".into())]]);
        assert!(!result.truncated);
    }

    #[test]
    fn redis_value_to_result_truncates_an_array_at_a_shared_budget() {
        let items = (0..MAX_QUERY_ROWS + 1).map(|i| RedisValue::Int(i as i64)).collect();
        let result = redis_value_to_result(RedisValue::Array(items));
        assert!(!result.rows.is_empty());
        assert!(result.rows.len() < MAX_QUERY_ROWS);
        assert!(result.truncated);
    }

    #[test]
    fn redis_value_to_result_maps_a_map_to_key_value_rows() {
        let result = redis_value_to_result(RedisValue::Map(vec![(
            RedisValue::SimpleString("field".into()),
            RedisValue::Int(7),
        )]));
        assert_eq!(result.rows, vec![vec![Value::Text("field".into()), Value::Int(7)]]);
    }

    #[test]
    fn redis_value_to_result_marks_a_truncated_map() {
        let pairs = (0..=MAX_QUERY_ROWS)
            .map(|index| {
                (
                    RedisValue::SimpleString(index.to_string()),
                    RedisValue::Int(index as i64),
                )
            })
            .collect();
        let result = redis_value_to_result(RedisValue::Map(pairs));
        assert!(!result.rows.is_empty());
        assert!(result.rows.len() < MAX_QUERY_ROWS);
        assert!(result.truncated, "a cut-off Redis map must never look complete");
    }

    #[test]
    fn redis_scalar_maps_nil_and_primitives() {
        assert_eq!(redis_scalar(RedisValue::Nil), Value::Null);
        assert_eq!(redis_scalar(RedisValue::Int(9)), Value::Int(9));
        assert_eq!(redis_scalar(RedisValue::Boolean(false)), Value::Bool(false));
        assert_eq!(redis_scalar(RedisValue::Okay), Value::Text("OK".into()));
    }

    #[test]
    fn redis_scalar_preserves_binary_that_is_not_utf8() {
        assert_eq!(
            redis_scalar(RedisValue::BulkString(b"abc".to_vec())),
            Value::Text("abc".into())
        );
        assert_eq!(
            redis_scalar(RedisValue::BulkString(vec![0xFF])),
            Value::Bytes(vec![0xFF])
        );
    }

    #[test]
    fn redis_nested_replies_keep_structure_and_binary_bytes() {
        let result = redis_value_to_result(RedisValue::Array(vec![
            RedisValue::Array(vec![RedisValue::BulkString(vec![0xFF, 0x00])]),
            RedisValue::Map(vec![(RedisValue::SimpleString("score".into()), RedisValue::Int(9))]),
            RedisValue::Set(vec![RedisValue::SimpleString("member".into())]),
            RedisValue::Array(vec![RedisValue::BigNumber("18446744073709551616".parse().unwrap())]),
        ]));

        assert_eq!(
            result.rows,
            vec![
                vec![Value::Json(serde_json::json!([{"$redisBytes": "ff00"}]))],
                vec![Value::Json(serde_json::json!({"$redisMap": [["score", 9]]}))],
                vec![Value::Json(serde_json::json!({"$redisSet": ["member"]}))],
                vec![Value::Json(
                    serde_json::json!([{"$redisBigNumber": "18446744073709551616"}])
                )],
            ]
        );
        assert_eq!(
            redis_scalar(RedisValue::BigNumber("18446744073709551616".parse().unwrap())),
            Value::Text("18446744073709551616".into())
        );
    }

    #[test]
    fn redis_resp3_attribute_and_push_keep_their_protocol_markers() {
        let attribute = redis_scalar(RedisValue::Attribute {
            data: Box::new(RedisValue::SimpleString("payload".into())),
            attributes: vec![(RedisValue::SimpleString("ttl".into()), RedisValue::Int(3))],
        });
        assert_eq!(
            attribute,
            Value::Json(serde_json::json!({
                "$redisAttribute": {
                    "data": "payload",
                    "attributes": [["ttl", 3]]
                }
            }))
        );

        let push = redis_scalar(RedisValue::Push {
            kind: redis::PushKind::Message,
            data: vec![
                RedisValue::SimpleString("updates".into()),
                RedisValue::BulkString(vec![0xFF]),
            ],
        });
        assert_eq!(
            push,
            Value::Json(serde_json::json!({
                "$redisPush": {
                    "kind": "Message",
                    "data": ["updates", {"$redisBytes": "ff"}]
                }
            }))
        );
    }

    #[test]
    fn redis_stream_commands_are_refused() {
        for command in [
            vec!["subscribe", "updates"],
            vec!["PSubscribe", "updates.*"],
            vec!["SSUBSCRIBE", "updates"],
            vec!["UNSUBSCRIBE", "updates"],
            vec!["punsubscribe", "updates.*"],
            vec!["sunsubscribe", "updates"],
            vec!["monitor"],
            vec!["CLIENT", "TRACKING", "ON"],
            vec!["client", "tracking", "on", "bcast"],
        ] {
            let args = command.into_iter().map(str::to_owned).collect::<Vec<_>>();
            assert!(is_redis_stream_command(&args), "{args:?}");
        }
        for command in [
            vec!["PING"],
            vec!["PUBLISH", "updates", "value"],
            vec!["PUBSUB", "CHANNELS"],
            vec!["GET", "key"],
            vec!["CLIENT", "TRACKING", "OFF"],
            vec!["CLIENT", "LIST"],
            vec![],
        ] {
            let args = command.into_iter().map(str::to_owned).collect::<Vec<_>>();
            assert!(!is_redis_stream_command(&args), "{args:?}");
        }
    }
}
