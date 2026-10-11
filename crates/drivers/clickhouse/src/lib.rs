use std::time::Duration;

mod query;
mod temporal;
mod tls;
mod value_literal;

use async_trait::async_trait;
use hyper_util::client::legacy::Client as HyperClient;
use hyper_util::rt::TokioExecutor;
use query::{
    LineReader, confirms_cancellation, exception_row_message, new_query_id, parse_line, request_cancellation, tag_query,
};
use secrecy::ExposeSecret;
use serde::Deserialize;
use tls::https_connector;
use value_literal::literal;

use tablepro_core::{
    ColumnInfo, ConnectOptions, Connection, DatabaseDriver, DriverError, ExecResult, ForeignKeyInfo, IndexInfo,
    MAX_QUERY_ROWS, OperationControl, QueryResult, QueryResultBudget, TableInfo, Value, error_chain_text,
    looks_like_tls_failure, run_server_cancellable, sql_dialect::quote_ident,
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
    fn supports_database_listing(&self) -> bool {
        true
    }

    fn id(&self) -> &'static str {
        DRIVER_ID
    }

    fn display_name(&self) -> &'static str {
        "ClickHouse"
    }

    fn default_port(&self) -> u16 {
        8123
    }

    fn default_database(&self) -> &'static str {
        "default"
    }

    fn default_username(&self) -> &'static str {
        "default"
    }

    fn reports_rows_affected(&self) -> bool {
        false
    }

    fn supports_index_metadata(&self) -> bool {
        true
    }

    async fn connect(&self, opts: ConnectOptions) -> Result<Box<dyn Connection>, DriverError> {
        let scheme = if opts.tls.mode.encrypts() { "https" } else { "http" };
        let url = format!("{scheme}://{}:{}", opts.host, opts.port);
        let http =
            HyperClient::builder(TokioExecutor::new()).build(https_connector(&opts.tls, opts.service_address().0)?);
        let mut client = clickhouse::Client::with_http_client(http)
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
            Ok(result) => result.map_err(|err| map_clickhouse_connect_error(err, opts.tls.mode.verifies_cert()))?,
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
        self.execute_tagged(sql, None).await
    }

    async fn execute_tagged(&self, sql: &str, query_id: Option<&str>) -> Result<u64, DriverError> {
        let mut cursor = tag_query(self.client.query(&escape_bind_markers(sql)), query_id)
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
    async fn list_databases(&self) -> Result<Vec<String>, DriverError> {
        #[derive(Debug, Deserialize, clickhouse::Row)]
        struct NameRow {
            name: String,
        }

        let rows = self
            .client
            .query(
                "SELECT name FROM system.databases
                 WHERE name NOT IN ('system', 'information_schema', 'INFORMATION_SCHEMA')
                 ORDER BY name",
            )
            .fetch_all::<NameRow>()
            .await
            .map_err(map_clickhouse_error)?;
        Ok(rows.into_iter().map(|row| row.name).collect())
    }

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
        let rows = self
            .client
            .query(
                "SELECT
                    name,
                    type,
                    is_in_primary_key,
                    default_kind,
                    default_expression,
                    comment
                 FROM system.columns
                 WHERE database = ?
                   AND table = ?
                 ORDER BY position",
            )
            .bind(self.database_of(schema))
            .bind(table)
            .fetch_all::<CatalogColumnRow>()
            .await
            .map_err(map_clickhouse_error)?;

        Ok(rows.into_iter().map(catalog_row_to_column_info).collect())
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
        fetch_result(&self.client, &sql, limit as usize, None).await
    }

    async fn query(&self, sql: &str) -> Result<QueryResult, DriverError> {
        fetch_result(&self.client, sql, MAX_QUERY_ROWS, None).await
    }

    async fn query_controlled(&self, sql: &str, control: &OperationControl) -> Result<QueryResult, DriverError> {
        let query_id = new_query_id();
        run_server_cancellable(
            fetch_result(&self.client, sql, MAX_QUERY_ROWS, Some(&query_id)),
            request_cancellation(&self.client, &query_id),
            confirms_cancellation,
            control,
        )
        .await
    }

    async fn query_params_controlled(
        &self,
        sql: &str,
        params: &[Value],
        control: &OperationControl,
    ) -> Result<QueryResult, DriverError> {
        if params.is_empty() {
            return self.query_controlled(sql, control).await;
        }
        let bound = bind_placeholders(sql, params)?;
        self.query_controlled(&bound, control).await
    }

    async fn execute_controlled(&self, sql: &str, control: &OperationControl) -> Result<ExecResult, DriverError> {
        let query_id = new_query_id();
        let rows_affected = run_server_cancellable(
            self.execute_tagged(sql, Some(&query_id)),
            request_cancellation(&self.client, &query_id),
            confirms_cancellation,
            control,
        )
        .await?;
        Ok(ExecResult { rows_affected })
    }

    async fn execute_params_controlled(
        &self,
        sql: &str,
        params: &[Value],
        control: &OperationControl,
    ) -> Result<ExecResult, DriverError> {
        if params.is_empty() {
            return self.execute_controlled(sql, control).await;
        }
        let bound = bind_placeholders(sql, params)?;
        self.execute_controlled(&bound, control).await
    }

    fn supports_server_cancellation(&self) -> bool {
        true
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
            predicate: None,
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

async fn fetch_result(
    client: &clickhouse::Client,
    sql: &str,
    max_rows: usize,
    query_id: Option<&str>,
) -> Result<QueryResult, DriverError> {
    let cursor = tag_query(client.query(&escape_bind_markers(sql)), query_id)
        .with_setting("output_format_json_quote_denormals", "1")
        .with_setting("output_format_decimal_trailing_zeros", "1")
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

    let columns = response_columns(names, types)?;

    let mut rows: Vec<Vec<Value>> = Vec::new();
    let mut budget = QueryResultBudget::default();
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
        if let Some(message) = exception_row_message(&raw) {
            return Err(DriverError::Query {
                message: message.to_owned(),
                sqlstate: None,
                position: None,
            });
        }
        let row = response_row(raw, &columns)?;
        if !budget.admit(&row) {
            truncated = true;
            break;
        }
        rows.push(row);
    }

    Ok(QueryResult {
        columns,
        rows,
        truncated,
    })
}

fn response_columns(names: Vec<String>, types: Vec<String>) -> Result<Vec<ColumnInfo>, DriverError> {
    if names.len() != types.len() {
        return Err(DriverError::Internal(format!(
            "clickhouse response column name/type count mismatch: {} names, {} types",
            names.len(),
            types.len()
        )));
    }
    Ok(names
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
            comment: None,
            collation: None,
            enum_type: None,
            domain_type: None,
        })
        .collect())
}

fn response_row(raw: Vec<serde_json::Value>, columns: &[ColumnInfo]) -> Result<Vec<Value>, DriverError> {
    if raw.len() != columns.len() {
        return Err(DriverError::Internal(format!(
            "clickhouse response row width mismatch: {} values, {} columns",
            raw.len(),
            columns.len()
        )));
    }
    Ok(columns
        .iter()
        .enumerate()
        .map(|(index, column)| json_to_value(raw[index].clone(), &column.data_type))
        .collect())
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
#[derive(Debug, Deserialize, clickhouse::Row)]
struct CatalogColumnRow {
    name: String,
    #[serde(rename = "type")]
    data_type: String,
    is_in_primary_key: u8,
    default_kind: String,
    default_expression: String,
    comment: String,
}

fn catalog_row_to_column_info(r: CatalogColumnRow) -> ColumnInfo {
    let is_generated = matches!(r.default_kind.as_str(), "MATERIALIZED" | "ALIAS" | "EPHEMERAL");
    let default_value = if r.default_expression.is_empty() {
        None
    } else {
        Some(r.default_expression)
    };
    // system.columns.comment is an empty string, never NULL, for a
    // column with no comment.
    let comment = Some(r.comment).filter(|c| !c.is_empty());
    ColumnInfo {
        nullable: type_is_nullable(&r.data_type),
        name: r.name,
        data_type: r.data_type,
        // A MergeTree sorting key is the closest thing to a row
        // identifier ClickHouse has, but it is not unique. The edit
        // path needs *some* key to build a WHERE from; see
        // `fetch_indexes` for why it is not advertised as unique.
        primary_key: r.is_in_primary_key != 0,
        is_auto_increment: false,
        default_value,
        is_generated,
        comment,
        collation: None,
        enum_type: None,
        domain_type: None,
    }
}

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
        "Decimal" | "Decimal32" | "Decimal64" | "Decimal128" | "Decimal256" => {
            let text = raw.as_str().map(str::to_owned).unwrap_or_else(|| raw.to_string());
            rust_decimal::Decimal::from_str_exact(&text)
                .map(Value::Decimal)
                .unwrap_or(Value::Text(text))
        }
        "Date" | "Date32" => raw
            .as_str()
            .and_then(|s| chrono::NaiveDate::parse_from_str(s, "%Y-%m-%d").ok())
            .map(Value::Date)
            .unwrap_or_else(|| fallback_text(&raw)),
        "DateTime" | "DateTime64" => temporal::parse_datetime(&raw, type_name),
        "UUID" => raw
            .as_str()
            .and_then(|s| s.parse::<uuid::Uuid>().ok())
            .map(Value::Uuid)
            .unwrap_or_else(|| fallback_text(&raw)),
        "Array" | "Map" | "Tuple" | "Nested" | "JSON" | "Object" | "Variant" | "Dynamic" => Value::Json(raw),
        _ => fallback_text(&raw),
    }
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

/// The `clickhouse` crate treats every `?` in a query template as one of
/// its own bind markers and `??` as an escaped literal. Statements this
/// driver sends are already fully rendered, so any `?` left in them is
/// data: a value inlined by `bind_placeholders`, or a question mark the
/// user typed in the SQL editor. Without escaping, the crate rejects the
/// query as having unbound arguments before it ever reaches the server.
fn escape_bind_markers(sql: &str) -> String {
    sql.replace('?', "??")
}

/// ClickHouse error codes that mean the credentials were rejected.
/// 192 UNKNOWN_USER, 193 WRONG_PASSWORD, 194 REQUIRED_PASSWORD,
/// 497 ACCESS_DENIED, 516 AUTHENTICATION_FAILED.
const AUTH_CODES: [&str; 5] = ["code: 192", "code: 193", "code: 194", "code: 497", "code: 516"];

fn map_clickhouse_connect_error(err: clickhouse::error::Error, verifies_cert: bool) -> DriverError {
    let is_ambiguous_network_disconnect = matches!(&err, clickhouse::error::Error::Network(_));
    match map_clickhouse_error_in_context(err, true) {
        DriverError::Disconnected if verifies_cert && is_ambiguous_network_disconnect => {
            DriverError::Tls("certificate hostname mismatch; connection closed during TLS verification".into())
        }
        other => other,
    }
}

fn map_clickhouse_error(err: clickhouse::error::Error) -> DriverError {
    map_clickhouse_error_in_context(err, false)
}

fn map_clickhouse_error_in_context(err: clickhouse::error::Error, connecting: bool) -> DriverError {
    let chain = error_chain_text(&err);
    let lower = chain.to_ascii_lowercase();
    match &err {
        clickhouse::error::Error::Network(_) => {
            if looks_like_tls_failure(&lower) {
                DriverError::Tls(chain)
            } else if connecting && (lower.contains("connection refused") || lower.contains("connect error")) {
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
                    message: err.to_string(),
                    sqlstate: None,
                    position: None,
                }
            }
        }
    }
}

#[cfg(test)]
mod tests;
