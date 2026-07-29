use std::time::Duration;

use async_trait::async_trait;
use secrecy::ExposeSecret;
use serde::Deserialize;

use tablepro_core::{
    ColumnInfo, ConnectOptions, Connection, DatabaseDriver, DriverError, ExecResult, ForeignKeyInfo, IndexInfo,
    MAX_QUERY_ROWS, QueryResult, TableInfo, Value, sql_dialect::quote_ident,
};

const DRIVER_ID: &str = "clickhouse";

/// Applies to the reachability probe in `connect` and to `ping`. The
/// `clickhouse` crate drives hyper, which has no default timeout, so a
/// black-holed host would otherwise hang the connect dialog forever.
/// Queries stay unbounded: an analytical query that runs for minutes is
/// legitimate and the user can close the tab to drop it.
const PROBE_TIMEOUT: Duration = Duration::from_secs(5);

/// Newline-delimited format carrying column names on line 1 and column
/// types on line 2. Preferred over `JSON` because it streams: rows
/// arrive one line at a time, so a `SELECT *` over a billion-row table
/// stops at `MAX_QUERY_ROWS` instead of buffering the whole result.
const ROW_FORMAT: &str = "JSONCompactEachRowWithNamesAndTypes";

pub struct ClickhouseDriver;

#[async_trait]
impl DatabaseDriver for ClickhouseDriver {
    fn id(&self) -> &'static str {
        DRIVER_ID
    }

    fn display_name(&self) -> &'static str {
        "ClickHouse"
    }

    fn default_port(&self) -> u16 {
        8123
    }

    fn reports_rows_affected(&self) -> bool {
        false
    }

    async fn connect(&self, opts: ConnectOptions) -> Result<Box<dyn Connection>, DriverError> {
        let scheme = if opts.use_tls { "https" } else { "http" };
        let url = format!("{scheme}://{}:{}", opts.host, opts.port);
        let mut client = clickhouse::Client::default()
            .with_url(url)
            .with_product_info("tablepro-linux", env!("CARGO_PKG_VERSION"))
            // `ALTER TABLE … UPDATE` and `DELETE FROM` are queued as
            // asynchronous mutations by default, so a save would return
            // before the rows changed and the grid would refetch stale
            // values. Wait for the mutation to finish on the server we
            // are talking to.
            .with_setting("mutations_sync", "1");
        if !opts.username.is_empty() {
            client = client.with_user(opts.username);
        }
        if !opts.password.expose_secret().is_empty() {
            client = client.with_password(opts.password.expose_secret());
        }
        if !opts.database.is_empty() {
            client = client.with_database(opts.database.clone());
        }

        let probe = client.query("SELECT 1").execute();
        match tokio::time::timeout(PROBE_TIMEOUT, probe).await {
            Ok(result) => result.map_err(map_clickhouse_error)?,
            Err(_) => return Err(DriverError::ConnectionRefused),
        }

        let database = if opts.database.is_empty() {
            resolve_current_database(&client).await
        } else {
            opts.database
        };
        Ok(Box::new(ClickhouseConnection { client, database }))
    }
}

/// The catalog queries filter `system.tables` / `system.columns` by an
/// explicit database name, so an empty `ConnectOptions::database` has to
/// resolve to whatever the server picked for this user rather than being
/// assumed to be `default`.
async fn resolve_current_database(client: &clickhouse::Client) -> String {
    client
        .query("SELECT currentDatabase()")
        .fetch_one::<String>()
        .await
        .unwrap_or_else(|_| "default".into())
}

struct ClickhouseConnection {
    client: clickhouse::Client,
    database: String,
}

impl ClickhouseConnection {
    fn database_of<'a>(&'a self, schema: Option<&'a str>) -> &'a str {
        schema.unwrap_or(self.database.as_str())
    }

    /// Runs a statement and reports the row count the server put in
    /// `X-ClickHouse-Summary`. Meaningful for INSERT; mutations report
    /// nothing, which is why the driver declares
    /// `reports_rows_affected() == false`.
    async fn execute_reporting(&self, sql: &str) -> Result<u64, DriverError> {
        let mut cursor = self
            .client
            .query(&escape_bind_markers(sql))
            // The summary header is sent before the body, so its counts
            // are only complete once the server has finished the query.
            .with_setting("wait_end_of_query", "1")
            .fetch_bytes(ROW_FORMAT)
            .map_err(map_clickhouse_error)?;
        while cursor.next().await.map_err(map_clickhouse_error)?.is_some() {}
        Ok(cursor.summary().and_then(|s| s.written_rows()).unwrap_or(0))
    }
}

#[async_trait]
impl Connection for ClickhouseConnection {
    async fn list_tables(&self) -> Result<Vec<TableInfo>, DriverError> {
        #[derive(Debug, Deserialize, clickhouse::Row)]
        struct Row {
            database: String,
            name: String,
        }

        let rows = self
            .client
            .query(
                "SELECT database, name
                 FROM system.tables
                 WHERE database = ?
                   AND is_temporary = 0
                 ORDER BY name",
            )
            .bind(self.database.as_str())
            .fetch_all::<Row>()
            .await
            .map_err(map_clickhouse_error)?;

        Ok(rows
            .into_iter()
            .map(|r| TableInfo {
                schema: Some(r.database),
                name: r.name,
            })
            .collect())
    }

    async fn fetch_columns(&self, schema: Option<&str>, table: &str) -> Result<Vec<ColumnInfo>, DriverError> {
        #[derive(Debug, Deserialize, clickhouse::Row)]
        struct Row {
            name: String,
            #[serde(rename = "type")]
            data_type: String,
            is_in_primary_key: u8,
            default_kind: String,
            default_expression: String,
        }

        let rows = self
            .client
            .query(
                "SELECT
                    name,
                    type,
                    is_in_primary_key,
                    default_kind,
                    default_expression
                 FROM system.columns
                 WHERE database = ?
                   AND table = ?
                 ORDER BY position",
            )
            .bind(self.database_of(schema))
            .bind(table)
            .fetch_all::<Row>()
            .await
            .map_err(map_clickhouse_error)?;

        Ok(rows
            .into_iter()
            .map(|r| {
                let is_generated = matches!(r.default_kind.as_str(), "MATERIALIZED" | "ALIAS" | "EPHEMERAL");
                let default_value = if r.default_expression.is_empty() {
                    None
                } else {
                    Some(r.default_expression)
                };
                ColumnInfo {
                    nullable: type_is_nullable(&r.data_type),
                    name: r.name,
                    data_type: r.data_type,
                    // A MergeTree sorting key is the closest thing to a
                    // row identifier ClickHouse has, but it is not
                    // unique. The edit path needs *some* key to build a
                    // WHERE from; see `fetch_indexes` for why it is not
                    // advertised as unique.
                    primary_key: r.is_in_primary_key != 0,
                    is_auto_increment: false,
                    default_value,
                    is_generated,
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
        let qualified = qualify(self.database_of(schema), table);
        let sql = format!("SELECT * FROM {qualified} LIMIT {limit} OFFSET {offset}");
        fetch_result(&self.client, &sql, limit as usize).await
    }

    async fn query(&self, sql: &str) -> Result<QueryResult, DriverError> {
        fetch_result(&self.client, sql, MAX_QUERY_ROWS).await
    }

    async fn query_params(&self, sql: &str, params: &[Value]) -> Result<QueryResult, DriverError> {
        if params.is_empty() {
            return self.query(sql).await;
        }
        let bound = bind_placeholders(sql, params)?;
        self.query(&bound).await
    }

    async fn execute(&self, sql: &str) -> Result<ExecResult, DriverError> {
        let rows_affected = self.execute_reporting(sql).await?;
        Ok(ExecResult { rows_affected })
    }

    async fn execute_params(&self, sql: &str, params: &[Value]) -> Result<ExecResult, DriverError> {
        let bound = bind_placeholders(sql, params)?;
        self.execute(&bound).await
    }

    async fn execute_in_transaction(&self, statements: &[(String, Vec<Value>)]) -> Result<Vec<u64>, DriverError> {
        // ClickHouse has no multi-statement ACID transaction for DML, so
        // this cannot honour the trait's rollback contract: statements
        // before the failing one stay applied. The index in the returned
        // error is still the one that failed, which is what the caller
        // uses to flag the offending row.
        let mut affected = Vec::with_capacity(statements.len());
        for (i, (sql, params)) in statements.iter().enumerate() {
            match self.execute_params(sql, params).await {
                Ok(r) => affected.push(r.rows_affected),
                Err(e) => {
                    return Err(DriverError::Transaction {
                        statement_index: i,
                        source: Box::new(e),
                    });
                }
            }
        }
        Ok(affected)
    }

    async fn fetch_indexes(&self, schema: Option<&str>, table: &str) -> Result<Vec<IndexInfo>, DriverError> {
        #[derive(Debug, Deserialize, clickhouse::Row)]
        struct Row {
            name: String,
            primary_key: String,
        }

        let rows = self
            .client
            .query(
                "SELECT name, primary_key
                 FROM system.tables
                 WHERE database = ?
                   AND name = ?
                 LIMIT 1",
            )
            .bind(self.database_of(schema))
            .bind(table)
            .fetch_all::<Row>()
            .await
            .map_err(map_clickhouse_error)?;

        let Some(row) = rows.into_iter().next() else {
            return Ok(Vec::new());
        };
        let columns = split_key_expression(&row.primary_key);
        if columns.is_empty() {
            return Ok(Vec::new());
        }
        Ok(vec![IndexInfo {
            name: format!("{}_sorting_key", row.name),
            columns,
            // A MergeTree primary key is a sparse sorting key, not a
            // uniqueness constraint: duplicate keys are legal and common.
            // Advertising it as unique would tell the UI that an UPDATE
            // built from these columns touches exactly one row.
            unique: false,
            primary: true,
        }])
    }

    async fn fetch_foreign_keys(
        &self,
        _schema: Option<&str>,
        _table: &str,
    ) -> Result<Vec<ForeignKeyInfo>, DriverError> {
        // ClickHouse has no classical FK constraints.
        Ok(Vec::new())
    }

    async fn ping(&self) -> Result<(), DriverError> {
        let probe = self.client.query("SELECT 1").execute();
        match tokio::time::timeout(PROBE_TIMEOUT, probe).await {
            Ok(result) => result.map_err(map_clickhouse_error),
            Err(_) => Err(DriverError::Disconnected),
        }
    }

    async fn close(self: Box<Self>) -> Result<(), DriverError> {
        Ok(())
    }
}

/// Reads a `ROW_FORMAT` response one line at a time so the caller can
/// stop at `max_rows` without materialising the rest of the result.
struct LineReader {
    cursor: clickhouse::query::BytesCursor,
    buf: Vec<u8>,
    consumed: usize,
    eof: bool,
}

impl LineReader {
    fn new(cursor: clickhouse::query::BytesCursor) -> Self {
        Self {
            cursor,
            buf: Vec::new(),
            consumed: 0,
            eof: false,
        }
    }

    async fn next_line(&mut self) -> Result<Option<Vec<u8>>, DriverError> {
        loop {
            if let Some(idx) = self.buf[self.consumed..].iter().position(|b| *b == b'\n') {
                let end = self.consumed + idx;
                let line = self.buf[self.consumed..end].to_vec();
                self.consumed = end + 1;
                return Ok(Some(line));
            }
            if self.eof {
                let rest = self.buf[self.consumed..].to_vec();
                self.consumed = self.buf.len();
                return Ok((!rest.is_empty()).then_some(rest));
            }
            match self.cursor.next().await.map_err(map_clickhouse_error)? {
                Some(chunk) => {
                    self.buf.drain(..self.consumed);
                    self.consumed = 0;
                    self.buf.extend_from_slice(&chunk);
                }
                None => self.eof = true,
            }
        }
    }
}

fn parse_line<T: serde::de::DeserializeOwned>(line: &[u8]) -> Result<T, DriverError> {
    serde_json::from_slice(line).map_err(|e| DriverError::Internal(format!("clickhouse response parse: {e}")))
}

async fn fetch_result(client: &clickhouse::Client, sql: &str, max_rows: usize) -> Result<QueryResult, DriverError> {
    let cursor = client
        .query(&escape_bind_markers(sql))
        .fetch_bytes(ROW_FORMAT)
        .map_err(map_clickhouse_error)?;
    let mut reader = LineReader::new(cursor);

    // A statement with no result set (DDL, INSERT) sends an empty body.
    let Some(names_line) = reader.next_line().await? else {
        return Ok(empty_result());
    };
    let names: Vec<String> = parse_line(&names_line)?;
    let Some(types_line) = reader.next_line().await? else {
        return Ok(empty_result());
    };
    let types: Vec<String> = parse_line(&types_line)?;

    let columns: Vec<ColumnInfo> = names
        .into_iter()
        .zip(types)
        .map(|(name, data_type)| ColumnInfo {
            nullable: type_is_nullable(&data_type),
            name,
            data_type,
            primary_key: false,
            is_auto_increment: false,
            default_value: None,
            is_generated: false,
        })
        .collect();

    let mut rows: Vec<Vec<Value>> = Vec::new();
    let mut truncated = false;
    while let Some(line) = reader.next_line().await? {
        if line.is_empty() {
            continue;
        }
        // Read one line past the cap so the flag reflects rows the
        // server actually had, not a result that happens to land on it.
        if rows.len() == max_rows {
            truncated = true;
            break;
        }
        let raw: Vec<serde_json::Value> = parse_line(&line)?;
        let mut row = Vec::with_capacity(columns.len());
        for (i, col) in columns.iter().enumerate() {
            let cell = raw.get(i).cloned().unwrap_or(serde_json::Value::Null);
            row.push(json_to_value(cell, &col.data_type));
        }
        rows.push(row);
    }

    Ok(QueryResult {
        columns,
        rows,
        truncated,
    })
}

fn empty_result() -> QueryResult {
    QueryResult {
        columns: Vec::new(),
        rows: Vec::new(),
        truncated: false,
    }
}

/// Peels the wrappers that do not change how a value is encoded, then
/// drops any type arguments. `LowCardinality(Nullable(String))` becomes
/// `String`, `Decimal(9, 2)` becomes `Decimal`, `DateTime64(3, 'UTC')`
/// becomes `DateTime64`. Matching the raw name instead would miss every
/// parameterised type, since the server always reports its arguments.
fn base_type(type_name: &str) -> &str {
    let mut t = type_name.trim();
    while let Some(inner) = unwrap_type(t, "LowCardinality").or_else(|| unwrap_type(t, "Nullable")) {
        t = inner;
    }
    t.split('(').next().unwrap_or(t).trim()
}

/// `Nullable(T)` survives inside `LowCardinality`, so the wrapper has to
/// come off before the nullability test.
fn type_is_nullable(type_name: &str) -> bool {
    let t = type_name.trim();
    let inner = unwrap_type(t, "LowCardinality").unwrap_or(t);
    unwrap_type(inner, "Nullable").is_some()
}

fn unwrap_type<'a>(type_name: &'a str, wrapper: &str) -> Option<&'a str> {
    type_name
        .strip_prefix(wrapper)?
        .strip_prefix('(')?
        .strip_suffix(')')
        .map(str::trim)
}

fn json_to_value(raw: serde_json::Value, type_name: &str) -> Value {
    if raw.is_null() {
        return Value::Null;
    }
    match base_type(type_name) {
        "Bool" => raw
            .as_bool()
            .map(Value::Bool)
            .or_else(|| raw.as_u64().map(|n| Value::Bool(n != 0)))
            .unwrap_or_else(|| fallback_text(&raw)),
        "Int8" | "Int16" | "Int32" | "Int64" | "UInt8" | "UInt16" | "UInt32" | "UInt64" => raw
            .as_i64()
            .or_else(|| raw.as_u64().and_then(|n| i64::try_from(n).ok()))
            .or_else(|| raw.as_str().and_then(|s| s.parse::<i64>().ok()))
            .map(Value::Int)
            // Int128 / UInt64 past i64::MAX have no lossless `Value`.
            // Text keeps every digit; Float would round.
            .unwrap_or_else(|| fallback_text(&raw)),
        "Float32" | "Float64" => raw
            .as_f64()
            .or_else(|| raw.as_str().and_then(|s| s.parse::<f64>().ok()))
            .map(Value::Float)
            .unwrap_or_else(|| fallback_text(&raw)),
        "Decimal" | "Decimal32" | "Decimal64" | "Decimal128" | "Decimal256" => raw
            .as_str()
            .and_then(|s| s.parse::<rust_decimal::Decimal>().ok())
            .or_else(|| raw.as_f64().and_then(|f| rust_decimal::Decimal::try_from(f).ok()))
            .map(Value::Decimal)
            .unwrap_or_else(|| fallback_text(&raw)),
        "Date" | "Date32" => raw
            .as_str()
            .and_then(|s| chrono::NaiveDate::parse_from_str(s, "%Y-%m-%d").ok())
            .map(Value::Date)
            .unwrap_or_else(|| fallback_text(&raw)),
        "DateTime" | "DateTime64" => parse_datetime(&raw),
        "UUID" => raw
            .as_str()
            .and_then(|s| s.parse::<uuid::Uuid>().ok())
            .map(Value::Uuid)
            .unwrap_or_else(|| fallback_text(&raw)),
        "String" | "FixedString" | "Enum8" | "Enum16" | "IPv4" | "IPv6" => fallback_text(&raw),
        "Array" | "Map" | "Tuple" | "Nested" | "JSON" | "Object" | "Variant" | "Dynamic" => Value::Json(raw),
        _ => fallback_text(&raw),
    }
}

fn parse_datetime(raw: &serde_json::Value) -> Value {
    let Some(s) = raw.as_str() else {
        return fallback_text(raw);
    };
    if let Ok(dt) = chrono::DateTime::parse_from_rfc3339(s) {
        return Value::TimestampTz(dt.with_timezone(&chrono::Utc));
    }
    // `%.f` also matches a whole-second timestamp, so one pattern covers
    // both `DateTime` and every `DateTime64` precision.
    if let Ok(dt) = chrono::NaiveDateTime::parse_from_str(s, "%Y-%m-%d %H:%M:%S%.f") {
        return Value::DateTime(dt);
    }
    Value::Text(s.to_string())
}

/// A JSON string keeps its own text; anything else keeps its JSON
/// spelling so no digits are lost on the way to the grid.
fn fallback_text(raw: &serde_json::Value) -> Value {
    match raw.as_str() {
        Some(s) => Value::Text(s.to_string()),
        None => Value::Text(raw.to_string()),
    }
}

/// Splits a `primary_key` expression from `system.tables` on top-level
/// commas only. A naive split breaks `toYYYYMM(d), id` into
/// `toYYYYMM(d` and `d), id`.
fn split_key_expression(expression: &str) -> Vec<String> {
    let mut parts = Vec::new();
    let mut depth = 0usize;
    let mut current = String::new();
    for ch in expression.chars() {
        match ch {
            '(' => {
                depth += 1;
                current.push(ch);
            }
            ')' => {
                depth = depth.saturating_sub(1);
                current.push(ch);
            }
            ',' if depth == 0 => {
                parts.push(std::mem::take(&mut current));
            }
            _ => current.push(ch),
        }
    }
    parts.push(current);
    parts
        .into_iter()
        .map(|s| s.trim().trim_matches('`').trim_matches('"').to_string())
        .filter(|s| !s.is_empty())
        .collect()
}

fn qualify(schema: &str, table: &str) -> String {
    format!("{}.{}", quote_ident(DRIVER_ID, schema), quote_ident(DRIVER_ID, table))
}

#[derive(Clone, Copy, PartialEq, Eq)]
enum ScanState {
    Sql,
    SingleQuote,
    DoubleQuote,
    Backtick,
    LineComment,
    BlockComment,
}

/// Inlines `Value`s as escaped SQL literals. ClickHouse's HTTP interface
/// has no positional binding, so the driver has to do the substitution
/// itself, which means it also has to know where SQL ends and a string
/// literal begins: a `?` inside `'what?'` is data, not a placeholder.
/// Filters carry user-typed text (`FilterOp::Raw` concatenates a whole
/// clause), so scanning blind would let one apostrophe shift every
/// binding after it.
fn bind_placeholders(sql: &str, params: &[Value]) -> Result<String, DriverError> {
    let mut out = String::with_capacity(sql.len() + params.len() * 8);
    let mut used = vec![false; params.len()];
    let mut next_positional = 0usize;
    let mut state = ScanState::Sql;
    let mut chars = sql.chars().peekable();

    while let Some(ch) = chars.next() {
        match state {
            ScanState::SingleQuote | ScanState::DoubleQuote | ScanState::Backtick => {
                out.push(ch);
                let closer = match state {
                    ScanState::SingleQuote => '\'',
                    ScanState::DoubleQuote => '"',
                    _ => '`',
                };
                if ch == '\\' {
                    // ClickHouse honours backslash escapes inside every
                    // quoted form, so the next character is literal.
                    if let Some(escaped) = chars.next() {
                        out.push(escaped);
                    }
                } else if ch == closer {
                    // A doubled quote is an escaped quote, not a close.
                    if chars.peek() == Some(&closer) {
                        out.push(closer);
                        chars.next();
                    } else {
                        state = ScanState::Sql;
                    }
                }
            }
            ScanState::LineComment => {
                out.push(ch);
                if ch == '\n' {
                    state = ScanState::Sql;
                }
            }
            ScanState::BlockComment => {
                out.push(ch);
                if ch == '*' && chars.peek() == Some(&'/') {
                    out.push('/');
                    chars.next();
                    state = ScanState::Sql;
                }
            }
            ScanState::Sql => match ch {
                '\'' | '"' | '`' => {
                    out.push(ch);
                    state = match ch {
                        '\'' => ScanState::SingleQuote,
                        '"' => ScanState::DoubleQuote,
                        _ => ScanState::Backtick,
                    };
                }
                '-' if chars.peek() == Some(&'-') => {
                    out.push_str("--");
                    chars.next();
                    state = ScanState::LineComment;
                }
                '/' if chars.peek() == Some(&'*') => {
                    out.push_str("/*");
                    chars.next();
                    state = ScanState::BlockComment;
                }
                '?' => {
                    let Some(value) = params.get(next_positional) else {
                        return Err(DriverError::Internal(format!(
                            "not enough bind parameters: need at least {}",
                            next_positional + 1
                        )));
                    };
                    out.push_str(&literal(value)?);
                    used[next_positional] = true;
                    next_positional += 1;
                }
                '$' => {
                    let mut digits = String::new();
                    while let Some(d) = chars.peek().copied().filter(char::is_ascii_digit) {
                        digits.push(d);
                        chars.next();
                    }
                    if digits.is_empty() {
                        out.push('$');
                        continue;
                    }
                    let n: usize = digits
                        .parse()
                        .map_err(|_| DriverError::Internal(format!("bad placeholder ${digits}")))?;
                    let Some(index) = n.checked_sub(1) else {
                        return Err(DriverError::Internal("bind placeholders start at $1".into()));
                    };
                    let Some(value) = params.get(index) else {
                        return Err(DriverError::Internal(format!(
                            "bind parameter ${n} out of range (have {})",
                            params.len()
                        )));
                    };
                    out.push_str(&literal(value)?);
                    used[index] = true;
                }
                _ => out.push(ch),
            },
        }
    }

    if let Some(unused) = used.iter().position(|u| !u) {
        return Err(DriverError::Internal(format!(
            "bind parameter {} of {} was never referenced",
            unused + 1,
            params.len()
        )));
    }
    Ok(out)
}

fn literal(value: &Value) -> Result<String, DriverError> {
    let rendered = match value {
        Value::Null => "NULL".into(),
        Value::Bool(b) => if *b { "true" } else { "false" }.into(),
        Value::Int(i) => i.to_string(),
        Value::Float(f) => {
            // ClickHouse spells these out; silently substituting NULL
            // would write a different value than the user typed.
            if f.is_nan() {
                "nan".into()
            } else if f.is_infinite() {
                if f.is_sign_negative() { "-inf" } else { "inf" }.into()
            } else {
                f.to_string()
            }
        }
        Value::Text(s) => format!("'{}'", escape_str(s)),
        Value::Bytes(b) => format!("unhex('{}')", hex_encode(b)),
        Value::Date(d) => format!("toDate('{}')", d.format("%Y-%m-%d")),
        Value::Time(t) => format!("'{}'", t.format("%H:%M:%S%.f")),
        Value::DateTime(dt) => format!("toDateTime('{}')", dt.format("%Y-%m-%d %H:%M:%S")),
        Value::TimestampTz(ts) => format!("toDateTime64('{}', 3)", ts.format("%Y-%m-%d %H:%M:%S%.3f")),
        Value::Decimal(d) => format!("toDecimal128('{d}', {})", d.scale()),
        Value::Uuid(u) => format!("toUUID('{u}')"),
        Value::Json(j) => format!("'{}'", escape_str(&j.to_string())),
    };
    Ok(rendered)
}

fn escape_str(s: &str) -> String {
    s.replace('\\', "\\\\").replace('\'', "\\'")
}

/// The `clickhouse` crate treats every `?` in a query template as one of
/// its own bind markers and `??` as an escaped literal. Statements this
/// driver sends are already fully rendered, so any `?` left in them is
/// data: a value inlined by `bind_placeholders`, or a question mark the
/// user typed in the SQL editor. Without escaping, the crate rejects the
/// query as having unbound arguments before it ever reaches the server.
fn escape_bind_markers(sql: &str) -> String {
    sql.replace('?', "??")
}

fn hex_encode(bytes: &[u8]) -> String {
    const LUT: &[u8; 16] = b"0123456789abcdef";
    let mut out = String::with_capacity(bytes.len() * 2);
    for b in bytes {
        out.push(LUT[(b >> 4) as usize] as char);
        out.push(LUT[(b & 0xf) as usize] as char);
    }
    out
}

/// ClickHouse error codes that mean the credentials were rejected.
/// 192 UNKNOWN_USER, 193 WRONG_PASSWORD, 194 REQUIRED_PASSWORD,
/// 497 ACCESS_DENIED, 516 AUTHENTICATION_FAILED.
const AUTH_CODES: [&str; 5] = ["code: 192", "code: 193", "code: 194", "code: 497", "code: 516"];

fn map_clickhouse_error(err: clickhouse::error::Error) -> DriverError {
    let msg = err.to_string();
    let lower = msg.to_lowercase();
    match &err {
        // Transport failures are the only place a TLS or refused-connect
        // diagnosis can come from. Matching those words against a server
        // response would misclassify a query that merely mentions them.
        clickhouse::error::Error::Network(_) => {
            if lower.contains("certificate") || lower.contains("tls") || lower.contains("handshake") {
                DriverError::Tls(msg)
            } else if lower.contains("connection refused") || lower.contains("connect error") {
                DriverError::ConnectionRefused
            } else {
                DriverError::Disconnected
            }
        }
        clickhouse::error::Error::TimedOut => DriverError::Disconnected,
        _ => {
            if AUTH_CODES.iter().any(|code| lower.contains(code)) {
                DriverError::AuthFailed
            } else {
                DriverError::Query {
                    message: msg,
                    sqlstate: None,
                }
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn driver_metadata() {
        let d = ClickhouseDriver;
        assert_eq!(d.id(), "clickhouse");
        assert_eq!(d.display_name(), "ClickHouse");
        assert_eq!(d.default_port(), 8123);
        assert!(!d.reports_rows_affected());
    }

    #[test]
    fn qualify_escapes_backticks() {
        assert_eq!(qualify("db", "users"), "`db`.`users`");
        assert_eq!(qualify("db", "a`b"), "`db`.`a``b`");
    }

    #[test]
    fn base_type_strips_arguments_and_wrappers() {
        assert_eq!(base_type("String"), "String");
        assert_eq!(base_type("Decimal(9, 2)"), "Decimal");
        assert_eq!(base_type("DateTime64(3, 'UTC')"), "DateTime64");
        assert_eq!(base_type("FixedString(16)"), "FixedString");
        assert_eq!(base_type("Nullable(Decimal(18, 4))"), "Decimal");
        assert_eq!(base_type("LowCardinality(Nullable(String))"), "String");
        assert_eq!(base_type("Array(Nullable(String))"), "Array");
        assert_eq!(base_type("Map(String, UInt64)"), "Map");
    }

    #[test]
    fn nullability_survives_low_cardinality() {
        assert!(!type_is_nullable("String"));
        assert!(type_is_nullable("Nullable(String)"));
        assert!(type_is_nullable("LowCardinality(Nullable(String))"));
        assert!(!type_is_nullable("LowCardinality(String)"));
        // The inner Nullable belongs to the element, not the column.
        assert!(!type_is_nullable("Array(Nullable(String))"));
    }

    #[test]
    fn parameterised_types_decode_to_typed_values() {
        assert_eq!(
            json_to_value(serde_json::json!("12.34"), "Decimal(9, 2)"),
            Value::Decimal("12.34".parse().unwrap())
        );
        assert_eq!(
            json_to_value(serde_json::json!("2024-06-15 08:30:00.123"), "DateTime64(3)"),
            Value::DateTime(
                chrono::NaiveDate::from_ymd_opt(2024, 6, 15)
                    .unwrap()
                    .and_hms_milli_opt(8, 30, 0, 123)
                    .unwrap()
            )
        );
        assert_eq!(
            json_to_value(serde_json::json!("abc"), "LowCardinality(Nullable(String))"),
            Value::Text("abc".into())
        );
        assert_eq!(
            json_to_value(serde_json::json!("2024-06-15 08:30:00"), "DateTime"),
            Value::DateTime(
                chrono::NaiveDate::from_ymd_opt(2024, 6, 15)
                    .unwrap()
                    .and_hms_opt(8, 30, 0)
                    .unwrap()
            )
        );
    }

    #[test]
    fn json_to_value_maps_common_types() {
        assert_eq!(json_to_value(serde_json::json!(true), "Bool"), Value::Bool(true));
        assert_eq!(json_to_value(serde_json::json!(42), "Int64"), Value::Int(42));
        assert_eq!(
            json_to_value(serde_json::json!("hello"), "String"),
            Value::Text("hello".into())
        );
        assert_eq!(json_to_value(serde_json::Value::Null, "Nullable(String)"), Value::Null);
        assert_eq!(
            json_to_value(serde_json::json!("2024-06-15"), "Date"),
            Value::Date(chrono::NaiveDate::from_ymd_opt(2024, 6, 15).unwrap())
        );
        assert_eq!(
            json_to_value(serde_json::json!([1, 2]), "Array(UInt8)"),
            Value::Json(serde_json::json!([1, 2]))
        );
    }

    #[test]
    fn bind_question_marks() {
        let sql = bind_placeholders(
            "ALTER TABLE t UPDATE a = ? WHERE id = ?",
            &[Value::Text("x".into()), Value::Int(1)],
        )
        .unwrap();
        assert_eq!(sql, "ALTER TABLE t UPDATE a = 'x' WHERE id = 1");
    }

    #[test]
    fn bind_dollar_placeholders() {
        let sql = bind_placeholders(
            "ALTER TABLE t UPDATE a = $1 WHERE id = $2",
            &[Value::Text("x".into()), Value::Int(1)],
        )
        .unwrap();
        assert_eq!(sql, "ALTER TABLE t UPDATE a = 'x' WHERE id = 1");
    }

    #[test]
    fn placeholders_inside_literals_are_left_alone() {
        let sql = bind_placeholders("SELECT * FROM t WHERE note = 'what? $1' AND id = ?", &[Value::Int(7)]).unwrap();
        assert_eq!(sql, "SELECT * FROM t WHERE note = 'what? $1' AND id = 7");
    }

    #[test]
    fn placeholders_inside_comments_and_identifiers_are_left_alone() {
        let sql = bind_placeholders(
            "SELECT `we?rd`, /* $1 ? */ x -- ?\n FROM t WHERE id = ?",
            &[Value::Int(3)],
        )
        .unwrap();
        assert_eq!(sql, "SELECT `we?rd`, /* $1 ? */ x -- ?\n FROM t WHERE id = 3");
    }

    #[test]
    fn escaped_quote_does_not_end_a_literal() {
        let sql = bind_placeholders("SELECT * FROM t WHERE a = 'it''s ?' AND b = ?", &[Value::Int(1)]).unwrap();
        assert_eq!(sql, "SELECT * FROM t WHERE a = 'it''s ?' AND b = 1");

        let sql = bind_placeholders("SELECT * FROM t WHERE a = 'it\\'s ?' AND b = ?", &[Value::Int(1)]).unwrap();
        assert_eq!(sql, "SELECT * FROM t WHERE a = 'it\\'s ?' AND b = 1");
    }

    #[test]
    fn unreferenced_parameter_is_an_error() {
        let err = bind_placeholders("SELECT * FROM t WHERE id = ?", &[Value::Int(1), Value::Int(2)]).unwrap_err();
        assert!(matches!(err, DriverError::Internal(_)));
    }

    #[test]
    fn missing_parameter_is_an_error() {
        let err = bind_placeholders("SELECT * FROM t WHERE a = ? AND b = ?", &[Value::Int(1)]).unwrap_err();
        assert!(matches!(err, DriverError::Internal(_)));

        let err = bind_placeholders("SELECT * FROM t WHERE a = $3", &[Value::Int(1)]).unwrap_err();
        assert!(matches!(err, DriverError::Internal(_)));
    }

    #[test]
    fn text_literals_escape_quotes_and_backslashes() {
        assert_eq!(literal(&Value::Text("it's \\ ok".into())).unwrap(), "'it\\'s \\\\ ok'");
        assert_eq!(
            literal(&Value::Bytes(vec![0x00, 0xff, 0x0a])).unwrap(),
            "unhex('00ff0a')"
        );
    }

    #[test]
    fn non_finite_floats_use_clickhouse_spellings() {
        assert_eq!(literal(&Value::Float(f64::NAN)).unwrap(), "nan");
        assert_eq!(literal(&Value::Float(f64::INFINITY)).unwrap(), "inf");
        assert_eq!(literal(&Value::Float(f64::NEG_INFINITY)).unwrap(), "-inf");
    }

    #[test]
    fn decimal_literals_keep_their_scale() {
        assert_eq!(
            literal(&Value::Decimal("12.3400".parse().unwrap())).unwrap(),
            "toDecimal128('12.3400', 4)"
        );
    }

    #[test]
    fn question_marks_are_escaped_for_the_client_template() {
        assert_eq!(
            escape_bind_markers("SELECT * FROM t WHERE note = 'what?'"),
            "SELECT * FROM t WHERE note = 'what??'"
        );
        // `?fields` is the crate's other marker; escaping covers it too.
        assert_eq!(escape_bind_markers("SELECT ?fields FROM t"), "SELECT ??fields FROM t");
        assert_eq!(escape_bind_markers("SELECT 1"), "SELECT 1");
    }

    #[test]
    fn key_expression_splits_at_top_level_only() {
        assert_eq!(split_key_expression("id"), vec!["id"]);
        assert_eq!(split_key_expression("`a`, `b`"), vec!["a", "b"]);
        assert_eq!(split_key_expression("toYYYYMM(d), id"), vec!["toYYYYMM(d)", "id"]);
        assert!(split_key_expression("").is_empty());
    }

    #[test]
    fn map_error_classifies_auth() {
        let err = map_clickhouse_error(clickhouse::error::Error::BadResponse(
            "Code: 516. Authentication failed: password is incorrect".into(),
        ));
        assert!(matches!(err, DriverError::AuthFailed));
    }

    #[test]
    fn server_error_mentioning_certificate_stays_a_query_error() {
        let err = map_clickhouse_error(clickhouse::error::Error::BadResponse(
            "Code: 47. Unknown identifier: certificate".into(),
        ));
        assert!(matches!(err, DriverError::Query { .. }));
    }
}
