use async_trait::async_trait;
use chrono::{DateTime, NaiveDate, NaiveDateTime, NaiveTime, Utc};
use futures::TryStreamExt;
use rust_decimal::Decimal;
use secrecy::ExposeSecret;
use tiberius::{
    AuthMethod, Client, Column, ColumnData, ColumnType, Config, EncryptionLevel, FromSql, QueryItem, ToSql,
};
use tokio::net::TcpStream;
use tokio::sync::Mutex;
use tokio_util::compat::{Compat, TokioAsyncWriteCompatExt};

use tablepro_core::sql_dialect::build_order_and_pagination;
use tablepro_core::{
    AuthMode, ColumnInfo, ConnectOptions, Connection, DatabaseDriver, DriverError, ExecResult, ForeignKeyInfo,
    IndexInfo, MAX_QUERY_ROWS, QueryResult, TableInfo, Value,
};

type MssqlClient = Client<Compat<TcpStream>>;

/// Matches the `acquire_timeout` the sqlx-backed drivers give their
/// pools, so a dead host fails at the same speed on every engine.
const CONNECT_TIMEOUT: std::time::Duration = std::time::Duration::from_secs(5);

pub struct MssqlDriver;

#[async_trait]
impl DatabaseDriver for MssqlDriver {
    fn id(&self) -> &'static str {
        "mssql"
    }

    fn display_name(&self) -> &'static str {
        "SQL Server"
    }

    fn default_port(&self) -> u16 {
        1433
    }

    fn ddl_is_transactional(&self) -> bool {
        true
    }

    fn supports_integrated_auth(&self) -> bool {
        true
    }

    async fn connect(&self, opts: ConnectOptions) -> Result<Box<dyn Connection>, DriverError> {
        let mut config = Config::new();
        config.host(&opts.host);
        config.port(opts.port);
        config.database(&opts.database);
        config.authentication(match opts.auth_mode {
            // Windows integrated auth over Kerberos (GSSAPI). tiberius
            // uses the ambient ticket cache (from `kinit`) and the SPN
            // MSSQLSvc/<host>:<port>; username/password are ignored.
            AuthMode::Kerberos => AuthMethod::Integrated,
            AuthMode::Password => AuthMethod::sql_server(&opts.username, opts.password.expose_secret()),
        });
        // SQL Server always encrypts the login exchange; `Off` keeps the
        // post-login stream in the clear, `Required` encrypts everything.
        // No cert-path UI exists, so the server certificate is trusted
        // without verification, matching the sqlx drivers' Require /
        // Required modes.
        config.encryption(if opts.use_tls {
            EncryptionLevel::Required
        } else {
            EncryptionLevel::Off
        });
        config.trust_cert();

        // Neither the TCP dial nor the TDS login has its own deadline,
        // and an unreachable host would otherwise hang the connect
        // dialog for the OS SYN timeout. The budget covers both so the
        // failure arrives on the same scale as the sqlx drivers'
        // acquire_timeout.
        tokio::time::timeout(CONNECT_TIMEOUT, async {
            let tcp = TcpStream::connect(config.get_addr()).await.map_err(map_io_error)?;
            tcp.set_nodelay(true).map_err(map_io_error)?;
            Client::connect(config, tcp.compat_write())
                .await
                .map_err(map_tiberius_error)
        })
        .await
        .map_err(|_| DriverError::ConnectionRefused)?
        .map(|client| {
            Box::new(MssqlConnection {
                client: Mutex::new(client),
            }) as Box<dyn Connection>
        })
    }
}

struct MssqlConnection {
    client: Mutex<MssqlClient>,
}

#[async_trait]
impl Connection for MssqlConnection {
    async fn list_tables(&self) -> Result<Vec<TableInfo>, DriverError> {
        let sql = "SELECT s.name AS schema_name, t.name AS table_name \
                   FROM sys.tables t \
                   JOIN sys.schemas s ON t.schema_id = s.schema_id \
                   ORDER BY s.name, t.name";
        let mut client = self.client.lock().await;
        let result = run_query(&mut client, sql, &[], MAX_QUERY_ROWS).await?;
        Ok(result
            .rows
            .iter()
            .filter_map(|row| {
                let name = as_text(row.get(1))?;
                Some(TableInfo {
                    schema: as_text(row.first()),
                    name,
                })
            })
            .collect())
    }

    async fn fetch_columns(&self, schema: Option<&str>, table: &str) -> Result<Vec<ColumnInfo>, DriverError> {
        // sys catalog is authoritative: is_identity/is_computed are exact
        // flags, sys.default_constraints.definition carries the DEFAULT
        // expression, and the primary-key join flags PK members. Type text
        // is rebuilt from sys.types + length/precision so it reads like the
        // user's CREATE TABLE (e.g. `nvarchar(255)`, `decimal(18,2)`).
        let sql = "SELECT \
                       c.name AS col_name, \
                       ty.name AS type_name, \
                       c.max_length, \
                       c.precision, \
                       c.scale, \
                       c.is_nullable, \
                       c.is_identity, \
                       c.is_computed, \
                       dc.definition AS default_def, \
                       CASE WHEN pk.column_id IS NOT NULL THEN 1 ELSE 0 END AS is_pk \
                   FROM sys.columns c \
                   JOIN sys.objects o ON c.object_id = o.object_id \
                   JOIN sys.schemas sc ON o.schema_id = sc.schema_id \
                   JOIN sys.types ty ON c.user_type_id = ty.user_type_id \
                   LEFT JOIN sys.default_constraints dc ON dc.object_id = c.default_object_id \
                   LEFT JOIN ( \
                       SELECT ic.object_id, ic.column_id \
                       FROM sys.index_columns ic \
                       JOIN sys.indexes i ON i.object_id = ic.object_id AND i.index_id = ic.index_id \
                       WHERE i.is_primary_key = 1 \
                   ) pk ON pk.object_id = c.object_id AND pk.column_id = c.column_id \
                   WHERE o.name = @P1 AND sc.name = COALESCE(@P2, SCHEMA_NAME()) \
                   ORDER BY c.column_id";
        let mut client = self.client.lock().await;
        let result = run_query(
            &mut client,
            sql,
            &[text_param(table), schema_param(schema)],
            MAX_QUERY_ROWS,
        )
        .await?;
        Ok(result.rows.iter().map(|r| row_to_column_info(r.as_slice())).collect())
    }

    async fn fetch_rows(
        &self,
        schema: Option<&str>,
        table: &str,
        offset: u64,
        limit: u64,
    ) -> Result<QueryResult, DriverError> {
        let sql = format!(
            "SELECT * FROM {}{}",
            qualified(schema, table),
            build_order_and_pagination("mssql", None, limit, offset)
        );
        let mut client = self.client.lock().await;
        run_query(&mut client, &sql, &[], limit as usize).await
    }

    async fn query(&self, sql: &str) -> Result<QueryResult, DriverError> {
        let mut client = self.client.lock().await;
        run_query(&mut client, sql, &[], MAX_QUERY_ROWS).await
    }

    async fn query_params(&self, sql: &str, params: &[Value]) -> Result<QueryResult, DriverError> {
        let mut client = self.client.lock().await;
        run_query(&mut client, sql, params, MAX_QUERY_ROWS).await
    }

    async fn execute(&self, sql: &str) -> Result<ExecResult, DriverError> {
        let mut client = self.client.lock().await;
        let rows_affected = run_execute(&mut client, sql, &[]).await?;
        Ok(ExecResult { rows_affected })
    }

    async fn execute_params(&self, sql: &str, params: &[Value]) -> Result<ExecResult, DriverError> {
        let mut client = self.client.lock().await;
        let rows_affected = run_execute(&mut client, sql, params).await?;
        Ok(ExecResult { rows_affected })
    }

    async fn execute_in_transaction(&self, statements: &[(String, Vec<Value>)]) -> Result<Vec<u64>, DriverError> {
        let mut client = self.client.lock().await;
        exec_simple(&mut client, "BEGIN TRANSACTION").await?;
        let mut affected = Vec::with_capacity(statements.len());
        for (idx, (sql, params)) in statements.iter().enumerate() {
            let boxes = boxed_params(params);
            let refs: Vec<&dyn ToSql> = boxes.iter().map(|b| &**b as &dyn ToSql).collect();
            match client.execute(sql.as_str(), &refs).await {
                Ok(res) => affected.push(res.total()),
                Err(e) => {
                    let _ = exec_simple(&mut client, "ROLLBACK").await;
                    return Err(DriverError::Transaction {
                        statement_index: idx,
                        source: Box::new(map_tiberius_error(e)),
                    });
                }
            }
        }
        exec_simple(&mut client, "COMMIT").await?;
        Ok(affected)
    }

    async fn fetch_indexes(&self, schema: Option<&str>, table: &str) -> Result<Vec<IndexInfo>, DriverError> {
        // Flat rows (one per index column) ordered by key_ordinal; grouped
        // into IndexInfo below since TDS has no array aggregation.
        // INCLUDE columns are not part of the key and carry key_ordinal
        // 0, so leaving them in would both list them as key columns and
        // sort them ahead of the real ones.
        let sql = "SELECT i.name AS index_name, i.is_unique, i.is_primary_key, c.name AS col_name \
                   FROM sys.indexes i \
                   JOIN sys.index_columns ic ON ic.object_id = i.object_id AND ic.index_id = i.index_id \
                   JOIN sys.columns c ON c.object_id = ic.object_id AND c.column_id = ic.column_id \
                   JOIN sys.objects o ON o.object_id = i.object_id \
                   JOIN sys.schemas s ON s.schema_id = o.schema_id \
                   WHERE o.name = @P1 AND s.name = COALESCE(@P2, SCHEMA_NAME()) \
                     AND i.name IS NOT NULL AND i.type > 0 \
                     AND ic.is_included_column = 0 \
                   ORDER BY i.name, ic.key_ordinal";
        let mut client = self.client.lock().await;
        let result = run_query(
            &mut client,
            sql,
            &[text_param(table), schema_param(schema)],
            MAX_QUERY_ROWS,
        )
        .await?;
        let mut out: Vec<IndexInfo> = Vec::new();
        for row in &result.rows {
            let Some(name) = as_text(row.first()) else {
                continue;
            };
            let unique = as_bool(row.get(1)).unwrap_or(false);
            let primary = as_bool(row.get(2)).unwrap_or(false);
            let col = as_text(row.get(3)).unwrap_or_default();
            match out.iter_mut().find(|ix| ix.name == name) {
                Some(ix) => ix.columns.push(col),
                None => out.push(IndexInfo {
                    name,
                    columns: vec![col],
                    unique,
                    primary,
                }),
            }
        }
        Ok(out)
    }

    async fn fetch_foreign_keys(&self, schema: Option<&str>, table: &str) -> Result<Vec<ForeignKeyInfo>, DriverError> {
        let sql = "SELECT fk.name AS fk_name, \
                       cpar.name AS col_name, \
                       rs.name AS ref_schema, \
                       rt.name AS ref_table, \
                       cref.name AS ref_col, \
                       fk.delete_referential_action_desc, \
                       fk.update_referential_action_desc \
                   FROM sys.foreign_keys fk \
                   JOIN sys.foreign_key_columns fkc ON fkc.constraint_object_id = fk.object_id \
                   JOIN sys.objects o ON o.object_id = fk.parent_object_id \
                   JOIN sys.schemas s ON s.schema_id = o.schema_id \
                   JOIN sys.columns cpar ON cpar.object_id = fk.parent_object_id AND cpar.column_id = fkc.parent_column_id \
                   JOIN sys.objects rt ON rt.object_id = fk.referenced_object_id \
                   JOIN sys.schemas rs ON rs.schema_id = rt.schema_id \
                   JOIN sys.columns cref ON cref.object_id = fk.referenced_object_id AND cref.column_id = fkc.referenced_column_id \
                   WHERE o.name = @P1 AND s.name = COALESCE(@P2, SCHEMA_NAME()) \
                   ORDER BY fk.name, fkc.constraint_column_id";
        let mut client = self.client.lock().await;
        let result = run_query(
            &mut client,
            sql,
            &[text_param(table), schema_param(schema)],
            MAX_QUERY_ROWS,
        )
        .await?;
        let mut out: Vec<ForeignKeyInfo> = Vec::new();
        for row in &result.rows {
            let Some(name) = as_text(row.first()) else {
                continue;
            };
            let col = as_text(row.get(1)).unwrap_or_default();
            let ref_col = as_text(row.get(4)).unwrap_or_default();
            match out.iter_mut().find(|fk| fk.name == name) {
                Some(fk) => {
                    fk.columns.push(col);
                    fk.ref_columns.push(ref_col);
                }
                None => out.push(ForeignKeyInfo {
                    name,
                    columns: vec![col],
                    ref_schema: as_text(row.get(2)),
                    ref_table: as_text(row.get(3)).unwrap_or_default(),
                    ref_columns: vec![ref_col],
                    on_delete: as_text(row.get(5)).and_then(|d| map_referential_action(&d)),
                    on_update: as_text(row.get(6)).and_then(|d| map_referential_action(&d)),
                }),
            }
        }
        Ok(out)
    }

    async fn ping(&self) -> Result<(), DriverError> {
        let mut client = self.client.lock().await;
        exec_simple(&mut client, "SELECT 1").await
    }

    async fn close(self: Box<Self>) -> Result<(), DriverError> {
        self.client.into_inner().close().await.map_err(map_tiberius_error)
    }
}

async fn run_query(
    client: &mut MssqlClient,
    sql: &str,
    params: &[Value],
    limit: usize,
) -> Result<QueryResult, DriverError> {
    let boxes = boxed_params(params);
    let refs: Vec<&dyn ToSql> = boxes.iter().map(|b| &**b as &dyn ToSql).collect();
    let mut stream = client.query(sql, &refs).await.map_err(map_tiberius_error)?;
    let mut columns: Vec<ColumnInfo> = Vec::new();
    let mut rows: Vec<Vec<Value>> = Vec::new();
    let mut truncated = false;
    let mut seen_result_set = false;
    while let Some(item) = stream.try_next().await.map_err(map_tiberius_error)? {
        match item {
            // Metadata arrives before the rows it describes, so a
            // result set with no rows still reports its columns. A
            // second one means the batch produced another result set;
            // the grid renders a single column list, so stop rather
            // than file the next set's rows under these headers.
            QueryItem::Metadata(meta) => {
                if seen_result_set {
                    break;
                }
                seen_result_set = true;
                columns = meta.columns().iter().map(col_to_info).collect();
            }
            QueryItem::Row(row) => {
                if rows.len() >= limit {
                    truncated = true;
                    break;
                }
                rows.push(row.into_iter().map(|cd| column_data_to_value(&cd)).collect());
            }
        }
    }
    Ok(QueryResult {
        columns,
        rows,
        truncated,
    })
}

async fn run_execute(client: &mut MssqlClient, sql: &str, params: &[Value]) -> Result<u64, DriverError> {
    let boxes = boxed_params(params);
    let refs: Vec<&dyn ToSql> = boxes.iter().map(|b| &**b as &dyn ToSql).collect();
    let res = client.execute(sql, &refs).await.map_err(map_tiberius_error)?;
    Ok(res.total())
}

/// Run a statement whose result set we don't consume (transaction control,
/// `SELECT 1` liveness). The stream must be drained so the DONE token is
/// read and the connection is left ready for the next command.
async fn exec_simple(client: &mut MssqlClient, sql: &str) -> Result<(), DriverError> {
    let stream = client.simple_query(sql).await.map_err(map_tiberius_error)?;
    stream.into_results().await.map_err(map_tiberius_error)?;
    Ok(())
}

fn boxed_params(params: &[Value]) -> Vec<Box<dyn ToSql>> {
    params
        .iter()
        .map(|p| -> Box<dyn ToSql> {
            match p {
                // Type NULL as nvarchar: a typed-int NULL breaks COALESCE /
                // comparisons against string columns (e.g. the introspection
                // `COALESCE(@P, SCHEMA_NAME())`), while NULL always converts
                // cleanly into any target column type on INSERT/UPDATE.
                Value::Null => Box::new(Option::<String>::None),
                Value::Bool(b) => Box::new(*b),
                Value::Int(i) => Box::new(*i),
                Value::Float(f) => Box::new(*f),
                Value::Text(s) => Box::new(s.clone()),
                Value::Bytes(b) => Box::new(b.clone()),
                Value::Date(d) => Box::new(*d),
                Value::Time(t) => Box::new(*t),
                Value::DateTime(dt) => Box::new(*dt),
                Value::TimestampTz(ts) => Box::new(*ts),
                Value::Decimal(d) => Box::new(*d),
                Value::Uuid(u) => Box::new(*u),
                // TDS has no JSON type; SQL Server stores JSON as nvarchar.
                Value::Json(j) => Box::new(serde_json::to_string(j).unwrap_or_default()),
            }
        })
        .collect()
}

fn col_to_info(c: &Column) -> ColumnInfo {
    ColumnInfo {
        name: c.name().to_string(),
        data_type: column_type_to_string(c.column_type()),
        nullable: true,
        primary_key: false,
        is_auto_increment: false,
        default_value: None,
        is_generated: false,
    }
}

fn column_data_to_value(cd: &ColumnData<'static>) -> Value {
    match cd {
        ColumnData::Bit(v) => (*v).map(Value::Bool).unwrap_or(Value::Null),
        ColumnData::U8(v) => (*v).map(|n| Value::Int(i64::from(n))).unwrap_or(Value::Null),
        ColumnData::I16(v) => (*v).map(|n| Value::Int(i64::from(n))).unwrap_or(Value::Null),
        ColumnData::I32(v) => (*v).map(|n| Value::Int(i64::from(n))).unwrap_or(Value::Null),
        ColumnData::I64(v) => (*v).map(Value::Int).unwrap_or(Value::Null),
        ColumnData::F32(v) => (*v).map(|n| Value::Float(f64::from(n))).unwrap_or(Value::Null),
        ColumnData::F64(v) => (*v).map(Value::Float).unwrap_or(Value::Null),
        ColumnData::String(v) => v.as_ref().map(|s| Value::Text(s.to_string())).unwrap_or(Value::Null),
        ColumnData::Binary(v) => v.as_ref().map(|b| Value::Bytes(b.to_vec())).unwrap_or(Value::Null),
        ColumnData::Guid(v) => (*v).map(Value::Uuid).unwrap_or(Value::Null),
        ColumnData::Numeric(_) => Decimal::from_sql(cd)
            .ok()
            .flatten()
            .map(Value::Decimal)
            .unwrap_or(Value::Null),
        ColumnData::Date(_) => NaiveDate::from_sql(cd)
            .ok()
            .flatten()
            .map(Value::Date)
            .unwrap_or(Value::Null),
        ColumnData::Time(_) => NaiveTime::from_sql(cd)
            .ok()
            .flatten()
            .map(Value::Time)
            .unwrap_or(Value::Null),
        ColumnData::DateTime(_) | ColumnData::SmallDateTime(_) | ColumnData::DateTime2(_) => {
            NaiveDateTime::from_sql(cd)
                .ok()
                .flatten()
                .map(Value::DateTime)
                .unwrap_or(Value::Null)
        }
        ColumnData::DateTimeOffset(_) => DateTime::<Utc>::from_sql(cd)
            .ok()
            .flatten()
            .map(Value::TimestampTz)
            .unwrap_or(Value::Null),
        ColumnData::Xml(v) => v.as_ref().map(|x| Value::Text(x.to_string())).unwrap_or(Value::Null),
    }
}

fn column_type_to_string(ct: ColumnType) -> String {
    let name = match ct {
        ColumnType::Null => "null",
        ColumnType::Bit | ColumnType::Bitn => "bit",
        ColumnType::Int1 => "tinyint",
        ColumnType::Int2 => "smallint",
        ColumnType::Int4 => "int",
        ColumnType::Int8 => "bigint",
        ColumnType::Intn => "int",
        ColumnType::Float4 => "real",
        ColumnType::Float8 | ColumnType::Floatn => "float",
        ColumnType::Decimaln | ColumnType::Numericn => "decimal",
        ColumnType::Money | ColumnType::Money4 => "money",
        ColumnType::Datetime | ColumnType::Datetime4 | ColumnType::Datetimen => "datetime",
        ColumnType::Datetime2 => "datetime2",
        ColumnType::DatetimeOffsetn => "datetimeoffset",
        ColumnType::Daten => "date",
        ColumnType::Timen => "time",
        ColumnType::Guid => "uniqueidentifier",
        ColumnType::BigChar | ColumnType::BigVarChar => "varchar",
        ColumnType::NChar | ColumnType::NVarchar => "nvarchar",
        ColumnType::Text => "text",
        ColumnType::NText => "ntext",
        ColumnType::BigBinary | ColumnType::BigVarBin => "varbinary",
        ColumnType::Image => "image",
        ColumnType::Xml => "xml",
        ColumnType::Udt => "udt",
        ColumnType::SSVariant => "sql_variant",
    };
    name.to_string()
}

fn row_to_column_info(row: &[Value]) -> ColumnInfo {
    let type_name = as_text(row.get(1)).unwrap_or_default();
    let max_length = as_i64(row.get(2)).unwrap_or(0);
    let precision = as_i64(row.get(3)).unwrap_or(0);
    let scale = as_i64(row.get(4)).unwrap_or(0);
    let is_identity = as_bool(row.get(6)).unwrap_or(false);
    let default_raw = as_text(row.get(8));
    ColumnInfo {
        name: as_text(row.first()).unwrap_or_default(),
        data_type: format_mssql_type(&type_name, max_length, precision, scale),
        nullable: as_bool(row.get(5)).unwrap_or(true),
        primary_key: as_bool(row.get(9)).unwrap_or(false),
        is_auto_increment: is_identity,
        // IDENTITY columns carry an internal seed/increment, not a user
        // DEFAULT — suppress so the inline-insert UI treats them as auto.
        default_value: if is_identity {
            None
        } else {
            default_raw.map(|d| normalize_mssql_default(&d))
        },
        is_generated: as_bool(row.get(7)).unwrap_or(false),
    }
}

/// Rebuild a user-facing type string from `sys.types` metadata. `nvarchar`
/// / `nchar` store `max_length` in bytes (two per character); `-1` is the
/// `(max)` sentinel. Numeric types carry precision/scale.
fn format_mssql_type(type_name: &str, max_length: i64, precision: i64, scale: i64) -> String {
    match type_name.to_ascii_lowercase().as_str() {
        "varchar" | "char" | "varbinary" | "binary" => {
            if max_length < 0 {
                format!("{type_name}(max)")
            } else {
                format!("{type_name}({max_length})")
            }
        }
        "nvarchar" | "nchar" => {
            if max_length < 0 {
                format!("{type_name}(max)")
            } else {
                format!("{type_name}({})", max_length / 2)
            }
        }
        "decimal" | "numeric" => format!("{type_name}({precision},{scale})"),
        _ => type_name.to_string(),
    }
}

/// `sys.default_constraints.definition` wraps the expression in parentheses
/// (sometimes doubled) and quotes string literals: `((0))`, `('pending')`,
/// `(getdate())`. Peel balanced outer parens, then outer single quotes, so
/// the value reads like the user typed it — matching the other drivers.
fn normalize_mssql_default(raw: &str) -> String {
    let mut s = raw.trim();
    while outer_parens_wrap(s) {
        s = s[1..s.len() - 1].trim();
    }
    strip_outer_single_quotes(s)
}

fn outer_parens_wrap(s: &str) -> bool {
    let bytes = s.as_bytes();
    if bytes.len() < 2 || bytes[0] != b'(' || bytes[bytes.len() - 1] != b')' {
        return false;
    }
    let mut depth = 0i32;
    for (i, &b) in bytes.iter().enumerate() {
        match b {
            b'(' => depth += 1,
            b')' => {
                depth -= 1;
                // A close that returns to depth 0 before the final byte
                // means the leading `(` does not wrap the whole string
                // (e.g. `(a)+(b)`); don't strip.
                if depth == 0 && i != bytes.len() - 1 {
                    return false;
                }
            }
            _ => {}
        }
    }
    depth == 0
}

fn strip_outer_single_quotes(raw: &str) -> String {
    let bytes = raw.as_bytes();
    if bytes.len() >= 2 && bytes[0] == b'\'' && bytes[bytes.len() - 1] == b'\'' {
        return raw[1..raw.len() - 1].replace("''", "'");
    }
    raw.to_string()
}

/// Map SQL Server's `*_referential_action_desc` text to the canonical SQL
/// keyword the FK/DDL layer expects. `NO_ACTION` returns `None` so the DDL
/// builder omits the redundant clause.
fn map_referential_action(desc: &str) -> Option<String> {
    match desc.to_ascii_uppercase().as_str() {
        "CASCADE" => Some("CASCADE".into()),
        "SET_NULL" => Some("SET NULL".into()),
        "SET_DEFAULT" => Some("SET DEFAULT".into()),
        _ => None,
    }
}

fn quote_ident(name: &str) -> String {
    format!("[{}]", name.replace(']', "]]"))
}

fn qualified(schema: Option<&str>, table: &str) -> String {
    match schema {
        Some(s) => format!("{}.{}", quote_ident(s), quote_ident(table)),
        None => quote_ident(table),
    }
}

fn text_param(s: &str) -> Value {
    Value::Text(s.to_string())
}

fn schema_param(schema: Option<&str>) -> Value {
    match schema {
        Some(s) => Value::Text(s.to_string()),
        None => Value::Null,
    }
}

fn as_text(v: Option<&Value>) -> Option<String> {
    match v {
        Some(Value::Text(s)) => Some(s.clone()),
        _ => None,
    }
}

fn as_i64(v: Option<&Value>) -> Option<i64> {
    match v {
        Some(Value::Int(i)) => Some(*i),
        _ => None,
    }
}

fn as_bool(v: Option<&Value>) -> Option<bool> {
    match v {
        Some(Value::Bool(b)) => Some(*b),
        // sys catalog bit columns and the CASE-derived is_pk flag can arrive
        // as an integer depending on the shape of the projection.
        Some(Value::Int(i)) => Some(*i != 0),
        _ => None,
    }
}

fn map_io_error(e: std::io::Error) -> DriverError {
    if e.kind() == std::io::ErrorKind::ConnectionRefused {
        DriverError::ConnectionRefused
    } else {
        DriverError::Internal(e.to_string())
    }
}

fn map_tiberius_error(err: tiberius::error::Error) -> DriverError {
    use tiberius::error::Error as E;
    match err {
        E::Io { .. } => DriverError::Disconnected,
        E::Tls(msg) => DriverError::Tls(msg),
        E::Server(token) => {
            // 18456 = "Login failed for user"; surface as an auth failure so
            // the UI shows the right remediation instead of a raw SQL error.
            if token.code() == 18456 {
                DriverError::AuthFailed
            } else {
                DriverError::Query {
                    message: token.message().to_string(),
                    sqlstate: Some(token.state().to_string()),
                }
            }
        }
        E::Routing { host, port } => DriverError::Internal(format!("server requested routing to {host}:{port}")),
        other => DriverError::Internal(other.to_string()),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn driver_metadata() {
        let d = MssqlDriver;
        assert_eq!(d.id(), "mssql");
        assert_eq!(d.display_name(), "SQL Server");
        assert_eq!(d.default_port(), 1433);
        assert!(!d.is_file_based());
        assert!(d.supports_integrated_auth());
    }

    #[test]
    fn quote_ident_brackets_and_escapes() {
        assert_eq!(quote_ident("users"), "[users]");
        assert_eq!(quote_ident("My Table"), "[My Table]");
        assert_eq!(quote_ident("weird]name"), "[weird]]name]");
    }

    #[test]
    fn qualified_uses_bracket_quoting() {
        assert_eq!(qualified(Some("dbo"), "users"), "[dbo].[users]");
        assert_eq!(qualified(None, "users"), "[users]");
    }

    #[test]
    fn format_type_lengths_and_precision() {
        assert_eq!(format_mssql_type("int", 4, 10, 0), "int");
        assert_eq!(format_mssql_type("varchar", 255, 0, 0), "varchar(255)");
        assert_eq!(format_mssql_type("varchar", -1, 0, 0), "varchar(max)");
        // nvarchar max_length is in bytes: 510 bytes -> 255 chars.
        assert_eq!(format_mssql_type("nvarchar", 510, 0, 0), "nvarchar(255)");
        assert_eq!(format_mssql_type("nvarchar", -1, 0, 0), "nvarchar(max)");
        assert_eq!(format_mssql_type("decimal", 9, 18, 2), "decimal(18,2)");
    }

    #[test]
    fn normalize_default_peels_parens_and_quotes() {
        assert_eq!(normalize_mssql_default("((0))"), "0");
        assert_eq!(normalize_mssql_default("('pending')"), "pending");
        assert_eq!(normalize_mssql_default("(getdate())"), "getdate()");
        assert_eq!(normalize_mssql_default("(N'x')"), "N'x'");
        assert_eq!(normalize_mssql_default("('it''s')"), "it's");
    }

    #[test]
    fn normalize_default_leaves_unbalanced_alone() {
        // A leading `(` that doesn't wrap the whole expression must not be
        // stripped, or the value would be corrupted.
        assert_eq!(normalize_mssql_default("(a)+(b)"), "(a)+(b)");
    }

    #[test]
    fn referential_actions_map_to_keywords() {
        assert_eq!(map_referential_action("CASCADE"), Some("CASCADE".to_string()));
        assert_eq!(map_referential_action("SET_NULL"), Some("SET NULL".to_string()));
        assert_eq!(map_referential_action("SET_DEFAULT"), Some("SET DEFAULT".to_string()));
        assert_eq!(map_referential_action("NO_ACTION"), None);
    }

    #[test]
    fn column_type_names_are_human_readable() {
        assert_eq!(column_type_to_string(ColumnType::Int4), "int");
        assert_eq!(column_type_to_string(ColumnType::NVarchar), "nvarchar");
        assert_eq!(column_type_to_string(ColumnType::Datetime2), "datetime2");
        assert_eq!(column_type_to_string(ColumnType::Guid), "uniqueidentifier");
        assert_eq!(column_type_to_string(ColumnType::Bit), "bit");
    }
}
