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
mod tests;
