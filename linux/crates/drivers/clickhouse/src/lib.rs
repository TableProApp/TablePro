use async_trait::async_trait;
use secrecy::ExposeSecret;
use serde::Deserialize;

use tablepro_core::{
    ColumnInfo, ConnectOptions, Connection, DatabaseDriver, DriverError, ExecResult, ForeignKeyInfo, IndexInfo,
    MAX_QUERY_ROWS, QueryResult, TableInfo, Value,
};

pub struct ClickhouseDriver;

#[async_trait]
impl DatabaseDriver for ClickhouseDriver {
    fn id(&self) -> &'static str {
        "clickhouse"
    }

    fn display_name(&self) -> &'static str {
        "ClickHouse"
    }

    fn default_port(&self) -> u16 {
        8123
    }

    async fn connect(&self, opts: ConnectOptions) -> Result<Box<dyn Connection>, DriverError> {
        let scheme = if opts.use_tls { "https" } else { "http" };
        let url = format!("{scheme}://{}:{}", opts.host, opts.port);
        let mut client = clickhouse::Client::default()
            .with_url(url)
            .with_product_info("tablepro-linux", env!("CARGO_PKG_VERSION"));
        if !opts.username.is_empty() {
            client = client.with_user(opts.username);
        }
        if !opts.password.expose_secret().is_empty() {
            client = client.with_password(opts.password.expose_secret());
        }
        if !opts.database.is_empty() {
            client = client.with_database(opts.database.clone());
        }

        // Prove the HTTP endpoint is reachable and credentials work.
        client
            .query("SELECT 1")
            .execute()
            .await
            .map_err(map_clickhouse_error)?;

        Ok(Box::new(ClickhouseConnection {
            client,
            database: if opts.database.is_empty() {
                "default".into()
            } else {
                opts.database
            },
        }))
    }
}

struct ClickhouseConnection {
    client: clickhouse::Client,
    database: String,
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
                 WHERE database = currentDatabase()
                   AND is_temporary = 0
                   AND engine NOT LIKE '%View'
                 ORDER BY name",
            )
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

        let db = schema.unwrap_or(self.database.as_str());
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
            .bind(db)
            .bind(table)
            .fetch_all::<Row>()
            .await
            .map_err(map_clickhouse_error)?;

        Ok(rows
            .into_iter()
            .map(|r| {
                let is_generated = matches!(
                    r.default_kind.as_str(),
                    "MATERIALIZED" | "ALIAS" | "EPHEMERAL"
                );
                let default_value = if r.default_expression.is_empty() {
                    None
                } else {
                    Some(r.default_expression)
                };
                let nullable = r.data_type.starts_with("Nullable(");
                ColumnInfo {
                    name: r.name,
                    data_type: r.data_type,
                    nullable,
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
        let qualified = qualify(schema.unwrap_or(self.database.as_str()), table);
        let sql = format!("SELECT * FROM {qualified} LIMIT {limit} OFFSET {offset}");
        self.query(&sql).await
    }

    async fn query(&self, sql: &str) -> Result<QueryResult, DriverError> {
        query_json(&self.client, sql).await
    }

    async fn query_params(&self, sql: &str, params: &[Value]) -> Result<QueryResult, DriverError> {
        if params.is_empty() {
            return self.query(sql).await;
        }
        let bound = bind_placeholders(sql, params)?;
        self.query(&bound).await
    }

    async fn execute(&self, sql: &str) -> Result<ExecResult, DriverError> {
        self.client
            .query(sql)
            .execute()
            .await
            .map_err(map_clickhouse_error)?;
        // ClickHouse HTTP does not return rows_affected for arbitrary
        // mutations reliably; report 0 rather than invent a count.
        Ok(ExecResult { rows_affected: 0 })
    }

    async fn execute_params(&self, sql: &str, params: &[Value]) -> Result<ExecResult, DriverError> {
        let bound = bind_placeholders(sql, params)?;
        self.execute(&bound).await
    }

    async fn execute_in_transaction(&self, statements: &[(String, Vec<Value>)]) -> Result<Vec<u64>, DriverError> {
        // ClickHouse has no multi-statement ACID transaction for DML.
        // Run statements sequentially; on failure surface which index
        // failed. Callers already treat this as best-effort for CH.
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

        let db = schema.unwrap_or(self.database.as_str());
        let rows = self
            .client
            .query(
                "SELECT name, primary_key
                 FROM system.tables
                 WHERE database = ?
                   AND name = ?
                 LIMIT 1",
            )
            .bind(db)
            .bind(table)
            .fetch_all::<Row>()
            .await
            .map_err(map_clickhouse_error)?;

        let Some(row) = rows.into_iter().next() else {
            return Ok(Vec::new());
        };
        if row.primary_key.is_empty() {
            return Ok(Vec::new());
        }
        let columns: Vec<String> = row
            .primary_key
            .split(',')
            .map(|s| s.trim().trim_matches('`').trim_matches('"').to_string())
            .filter(|s| !s.is_empty())
            .collect();
        if columns.is_empty() {
            return Ok(Vec::new());
        }
        Ok(vec![IndexInfo {
            name: format!("{}_pk", row.name),
            columns,
            unique: true,
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
        self.client
            .query("SELECT 1")
            .execute()
            .await
            .map_err(map_clickhouse_error)
    }

    async fn close(self: Box<Self>) -> Result<(), DriverError> {
        Ok(())
    }
}

#[derive(Debug, Deserialize)]
struct JsonMeta {
    name: String,
    #[serde(rename = "type")]
    data_type: String,
}

#[derive(Debug, Deserialize)]
struct JsonResponse {
    #[serde(default)]
    meta: Vec<JsonMeta>,
    #[serde(default)]
    data: Vec<serde_json::Map<String, serde_json::Value>>,
    #[serde(default)]
    rows: u64,
}

async fn query_json(client: &clickhouse::Client, sql: &str) -> Result<QueryResult, DriverError> {
    let mut cursor = client
        .query(sql)
        .fetch_bytes("JSON")
        .map_err(map_clickhouse_error)?;
    let bytes = cursor.collect().await.map_err(map_clickhouse_error)?;
    if bytes.is_empty() {
        return Ok(QueryResult {
            columns: Vec::new(),
            rows: Vec::new(),
            truncated: false,
        });
    }

    let parsed: JsonResponse = serde_json::from_slice(&bytes)
        .map_err(|e| DriverError::Internal(format!("clickhouse JSON parse: {e}")))?;

    let columns: Vec<ColumnInfo> = parsed
        .meta
        .iter()
        .map(|m| ColumnInfo {
            name: m.name.clone(),
            data_type: m.data_type.clone(),
            nullable: m.data_type.starts_with("Nullable(") || m.data_type == "Nullable",
            primary_key: false,
            is_auto_increment: false,
            default_value: None,
            is_generated: false,
        })
        .collect();

    let mut rows = Vec::with_capacity(parsed.data.len().min(MAX_QUERY_ROWS));
    for obj in parsed.data.into_iter().take(MAX_QUERY_ROWS) {
        let mut row = Vec::with_capacity(columns.len());
        for col in &columns {
            let raw = obj.get(&col.name).cloned().unwrap_or(serde_json::Value::Null);
            row.push(json_to_value(raw, &col.data_type));
        }
        rows.push(row);
    }

    let truncated = parsed.rows as usize > rows.len() || rows.len() >= MAX_QUERY_ROWS;
    Ok(QueryResult {
        columns,
        rows,
        truncated,
    })
}

fn json_to_value(raw: serde_json::Value, type_name: &str) -> Value {
    if raw.is_null() {
        return Value::Null;
    }
    let base = strip_nullable(type_name);
    match base {
        "Bool" => raw
            .as_bool()
            .map(Value::Bool)
            .or_else(|| raw.as_u64().map(|n| Value::Bool(n != 0)))
            .unwrap_or_else(|| Value::Text(raw.to_string())),
        "Int8" | "Int16" | "Int32" | "Int64" | "UInt8" | "UInt16" | "UInt32" | "UInt64" => raw
            .as_i64()
            .or_else(|| raw.as_u64().and_then(|n| i64::try_from(n).ok()))
            .map(Value::Int)
            .or_else(|| {
                raw.as_str()
                    .and_then(|s| s.parse::<i64>().ok())
                    .map(Value::Int)
            })
            .unwrap_or_else(|| Value::Text(raw.to_string())),
        "Float32" | "Float64" => raw
            .as_f64()
            .map(Value::Float)
            .or_else(|| {
                raw.as_str()
                    .and_then(|s| s.parse::<f64>().ok())
                    .map(Value::Float)
            })
            .unwrap_or_else(|| Value::Text(raw.to_string())),
        "Decimal" | "Decimal32" | "Decimal64" | "Decimal128" | "Decimal256" => raw
            .as_str()
            .and_then(|s| s.parse::<rust_decimal::Decimal>().ok())
            .or_else(|| {
                raw.as_f64()
                    .and_then(|f| rust_decimal::Decimal::try_from(f).ok())
            })
            .map(Value::Decimal)
            .unwrap_or_else(|| Value::Text(raw.to_string())),
        "Date" => raw
            .as_str()
            .and_then(|s| chrono::NaiveDate::parse_from_str(s, "%Y-%m-%d").ok())
            .map(Value::Date)
            .unwrap_or_else(|| Value::Text(raw.as_str().unwrap_or(&raw.to_string()).to_string())),
        "DateTime" | "DateTime64" => {
            if let Some(s) = raw.as_str() {
                if let Ok(dt) = chrono::DateTime::parse_from_rfc3339(s) {
                    return Value::TimestampTz(dt.with_timezone(&chrono::Utc));
                }
                if let Ok(dt) = chrono::NaiveDateTime::parse_from_str(s, "%Y-%m-%d %H:%M:%S") {
                    return Value::DateTime(dt);
                }
                if let Ok(dt) = chrono::NaiveDateTime::parse_from_str(s, "%Y-%m-%d %H:%M:%S%.f") {
                    return Value::DateTime(dt);
                }
                return Value::Text(s.to_string());
            }
            Value::Text(raw.to_string())
        }
        "UUID" => raw
            .as_str()
            .and_then(|s| s.parse::<uuid::Uuid>().ok())
            .map(Value::Uuid)
            .unwrap_or_else(|| Value::Text(raw.as_str().unwrap_or(&raw.to_string()).to_string())),
        "String" | "FixedString" | "LowCardinality(String)" => {
            Value::Text(raw.as_str().unwrap_or(&raw.to_string()).to_string())
        }
        t if t.starts_with("Array") || t.starts_with("Map") || t.starts_with("Tuple") || t == "JSON"
            || t.starts_with("Object") =>
        {
            Value::Json(raw)
        }
        _ => {
            if let Some(s) = raw.as_str() {
                Value::Text(s.to_string())
            } else if let Some(n) = raw.as_i64() {
                Value::Int(n)
            } else if let Some(f) = raw.as_f64() {
                Value::Float(f)
            } else if let Some(b) = raw.as_bool() {
                Value::Bool(b)
            } else {
                Value::Json(raw)
            }
        }
    }
}

fn strip_nullable(type_name: &str) -> &str {
    type_name
        .strip_prefix("Nullable(")
        .and_then(|s| s.strip_suffix(')'))
        .unwrap_or(type_name)
}

fn qualify(schema: &str, table: &str) -> String {
    format!("{}.{}", quote_ident(schema), quote_ident(table))
}

fn quote_ident(name: &str) -> String {
    format!("`{}`", name.replace('`', "``"))
}

fn bind_placeholders(sql: &str, params: &[Value]) -> Result<String, DriverError> {
    let mut out = String::with_capacity(sql.len() + params.len() * 8);
    let mut param_idx = 0;
    let mut chars = sql.chars().peekable();
    while let Some(ch) = chars.next() {
        if ch == '?' {
            let Some(value) = params.get(param_idx) else {
                return Err(DriverError::Internal(format!(
                    "not enough bind parameters: need at least {}",
                    param_idx + 1
                )));
            };
            out.push_str(&literal(value));
            param_idx += 1;
            continue;
        }
        if ch == '$' {
            let mut digits = String::new();
            while let Some(d) = chars.peek().copied().filter(|c| c.is_ascii_digit()) {
                digits.push(d);
                chars.next();
            }
            if !digits.is_empty() {
                let n: usize = digits
                    .parse()
                    .map_err(|_| DriverError::Internal(format!("bad placeholder ${digits}")))?;
                let Some(value) = params.get(n.saturating_sub(1)) else {
                    return Err(DriverError::Internal(format!(
                        "bind parameter ${n} out of range (have {})",
                        params.len()
                    )));
                };
                out.push_str(&literal(value));
                continue;
            }
            out.push('$');
            continue;
        }
        out.push(ch);
    }
    if param_idx > 0 && param_idx != params.len() {
        return Err(DriverError::Internal(format!(
            "bind parameter count mismatch: used {param_idx}, have {}",
            params.len()
        )));
    }
    Ok(out)
}

fn literal(value: &Value) -> String {
    match value {
        Value::Null => "NULL".into(),
        Value::Bool(b) => if *b { "true" } else { "false" }.into(),
        Value::Int(i) => i.to_string(),
        Value::Float(f) => {
            if f.is_finite() {
                f.to_string()
            } else {
                "NULL".into()
            }
        }
        Value::Text(s) => format!("'{}'", escape_str(s)),
        Value::Bytes(b) => format!("unhex('{}')", hex::encode(b)),
        Value::Date(d) => format!("toDate('{}')", d),
        Value::Time(t) => format!("'{}'", t),
        Value::DateTime(dt) => format!("toDateTime('{}')", dt.format("%Y-%m-%d %H:%M:%S")),
        Value::TimestampTz(ts) => format!(
            "toDateTime64('{}', 3)",
            ts.format("%Y-%m-%d %H:%M:%S%.3f")
        ),
        Value::Decimal(d) => d.to_string(),
        Value::Uuid(u) => format!("toUUID('{}')", u),
        Value::Json(j) => format!("'{}'", escape_str(&j.to_string())),
    }
}

fn escape_str(s: &str) -> String {
    s.replace('\\', "\\\\").replace('\'', "\\'")
}

fn map_clickhouse_error(err: clickhouse::error::Error) -> DriverError {
    let msg = err.to_string();
    let lower = msg.to_lowercase();
    if lower.contains("connection refused") || lower.contains("connect error") {
        return DriverError::ConnectionRefused;
    }
    if lower.contains("authentication") || lower.contains("password is incorrect") || lower.contains("code: 516")
    {
        return DriverError::AuthFailed;
    }
    if lower.contains("tls") || lower.contains("certificate") {
        return DriverError::Tls(msg);
    }
    DriverError::Query {
        message: msg,
        sqlstate: None,
    }
}

// Minimal hex encoder so we do not pull the `hex` crate for one call site.
mod hex {
    pub fn encode(bytes: &[u8]) -> String {
        const LUT: &[u8; 16] = b"0123456789abcdef";
        let mut out = String::with_capacity(bytes.len() * 2);
        for b in bytes {
            out.push(LUT[(b >> 4) as usize] as char);
            out.push(LUT[(b & 0xf) as usize] as char);
        }
        out
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
    }

    #[test]
    fn quote_ident_escapes_backticks() {
        assert_eq!(quote_ident("users"), "`users`");
        assert_eq!(quote_ident("a`b"), "`a``b`");
    }

    #[test]
    fn bind_question_marks() {
        let sql = bind_placeholders(
            "UPDATE t SET a = ? WHERE id = ?",
            &[Value::Text("x".into()), Value::Int(1)],
        )
        .unwrap();
        assert_eq!(sql, "UPDATE t SET a = 'x' WHERE id = 1");
    }

    #[test]
    fn bind_dollar_placeholders() {
        let sql = bind_placeholders(
            "UPDATE t SET a = $1 WHERE id = $2",
            &[Value::Text("x".into()), Value::Int(1)],
        )
        .unwrap();
        assert_eq!(sql, "UPDATE t SET a = 'x' WHERE id = 1");
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
    }

    #[test]
    fn map_error_classifies_auth() {
        // Construct via Display path: we only have Query/Auth heuristics on strings.
        let err = map_clickhouse_error(clickhouse::error::Error::BadResponse(
            "Code: 516. Authentication failed: password is incorrect".into(),
        ));
        assert!(matches!(err, DriverError::AuthFailed));
    }
}
