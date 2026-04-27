use std::time::Duration;

use async_trait::async_trait;
use secrecy::ExposeSecret;
use sqlx::postgres::{PgConnectOptions, PgPoolOptions, PgRow};
use sqlx::{Column, Pool, Postgres, Row, TypeInfo};

use futures::stream::StreamExt;

use tablepro_core::{
    ColumnInfo, ConnectOptions, Connection, DatabaseDriver, DriverError, ExecResult, MAX_QUERY_ROWS, QueryResult,
    TableInfo, Value,
};

pub struct PgDriver;

#[async_trait]
impl DatabaseDriver for PgDriver {
    fn id(&self) -> &'static str {
        "postgres"
    }

    fn display_name(&self) -> &'static str {
        "PostgreSQL"
    }

    fn default_port(&self) -> u16 {
        5432
    }

    async fn connect(&self, opts: ConnectOptions) -> Result<Box<dyn Connection>, DriverError> {
        let pg_opts = PgConnectOptions::new()
            .host(&opts.host)
            .port(opts.port)
            .database(&opts.database)
            .username(&opts.username)
            .password(opts.password.expose_secret())
            .ssl_mode(if opts.use_tls {
                sqlx::postgres::PgSslMode::Require
            } else {
                sqlx::postgres::PgSslMode::Disable
            });
        let pool = PgPoolOptions::new()
            .max_connections(4)
            .acquire_timeout(Duration::from_secs(5))
            .connect_with(pg_opts)
            .await
            .map_err(map_sqlx_error)?;
        Ok(Box::new(PgConnection { pool }))
    }
}

struct PgConnection {
    pool: Pool<Postgres>,
}

#[async_trait]
impl Connection for PgConnection {
    async fn list_tables(&self) -> Result<Vec<TableInfo>, DriverError> {
        let rows = sqlx::query(
            "SELECT schemaname, tablename
             FROM pg_tables
             WHERE schemaname NOT IN ('pg_catalog', 'information_schema')
             ORDER BY schemaname, tablename",
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
        let rows = sqlx::query(
            "SELECT
                c.column_name,
                c.data_type,
                c.is_nullable,
                EXISTS (
                    SELECT 1
                    FROM information_schema.table_constraints tc
                    JOIN information_schema.key_column_usage kcu
                      ON tc.constraint_name = kcu.constraint_name
                     AND tc.table_schema = kcu.table_schema
                     AND tc.table_name = kcu.table_name
                    WHERE tc.constraint_type = 'PRIMARY KEY'
                      AND kcu.table_name = c.table_name
                      AND kcu.table_schema = c.table_schema
                      AND kcu.column_name = c.column_name
                ) AS is_pk,
                c.column_default,
                c.is_identity,
                c.is_generated
             FROM information_schema.columns c
             WHERE c.table_name = $1
               AND c.table_schema = COALESCE($2, current_schema())
             ORDER BY c.ordinal_position",
        )
        .bind(table)
        .bind(schema)
        .fetch_all(&self.pool)
        .await
        .map_err(map_sqlx_error)?;
        Ok(rows
            .into_iter()
            .map(|r| {
                let default_value: Option<String> = r.try_get::<Option<String>, _>(4).unwrap_or(None);
                let is_identity = r.try_get::<String, _>(5).map(|s| s == "YES").unwrap_or(false);
                // SERIAL/BIGSERIAL columns set column_default to a
                // `nextval(...)` expression but are not flagged as IDENTITY;
                // detect both forms.
                let is_serial = default_value
                    .as_deref()
                    .map(|d| d.starts_with("nextval("))
                    .unwrap_or(false);
                let is_generated = r.try_get::<String, _>(6).map(|s| s != "NEVER").unwrap_or(false);
                ColumnInfo {
                    name: r.get::<String, _>(0),
                    data_type: r.get::<String, _>(1),
                    nullable: r.get::<String, _>(2) == "YES",
                    primary_key: r.get::<bool, _>(3),
                    is_auto_increment: is_identity || is_serial,
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
        let sql = format!(
            "SELECT * FROM {} OFFSET {offset} LIMIT {limit}",
            qualified(schema, table)
        );
        stream_into_result(&self.pool, &sql, limit as usize).await
    }

    async fn query(&self, sql: &str) -> Result<QueryResult, DriverError> {
        stream_into_result(&self.pool, sql, MAX_QUERY_ROWS).await
    }

    async fn execute(&self, sql: &str) -> Result<ExecResult, DriverError> {
        let res = sqlx::query(sql).execute(&self.pool).await.map_err(map_sqlx_error)?;
        Ok(ExecResult {
            rows_affected: res.rows_affected(),
        })
    }

    async fn execute_params(&self, sql: &str, params: &[Value]) -> Result<ExecResult, DriverError> {
        let q = bind_pg_params(sqlx::query(sql), params);
        let res = q.execute(&self.pool).await.map_err(map_sqlx_error)?;
        Ok(ExecResult {
            rows_affected: res.rows_affected(),
        })
    }

    async fn execute_in_transaction(&self, statements: &[(String, Vec<Value>)]) -> Result<Vec<u64>, DriverError> {
        let mut tx = self.pool.begin().await.map_err(map_sqlx_error)?;
        let mut affected = Vec::with_capacity(statements.len());
        for (idx, (sql, params)) in statements.iter().enumerate() {
            let q = bind_pg_params(sqlx::query(sql), params);
            match q.execute(&mut *tx).await {
                Ok(res) => affected.push(res.rows_affected()),
                Err(e) => {
                    let _ = tx.rollback().await;
                    return Err(DriverError::Transaction {
                        statement_index: idx,
                        source: Box::new(map_sqlx_error(e)),
                    });
                }
            }
        }
        tx.commit().await.map_err(map_sqlx_error)?;
        Ok(affected)
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

async fn stream_into_result(pool: &Pool<Postgres>, sql: &str, limit: usize) -> Result<QueryResult, DriverError> {
    let mut stream = sqlx::query(sql).fetch(pool);
    let mut collected: Vec<PgRow> = Vec::new();
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
        return Ok(QueryResult {
            columns: Vec::new(),
            rows: Vec::new(),
            truncated,
        });
    }
    let columns: Vec<ColumnInfo> = collected[0]
        .columns()
        .iter()
        .map(|c| ColumnInfo {
            name: c.name().to_string(),
            data_type: c.type_info().name().to_string(),
            nullable: true,
            primary_key: false,
            is_auto_increment: false,
            default_value: None,
            is_generated: false,
        })
        .collect();
    let data: Vec<Vec<Value>> = collected
        .iter()
        .map(|r| (0..columns.len()).map(|i| extract_value(r, i)).collect())
        .collect();
    Ok(QueryResult {
        columns,
        rows: data,
        truncated,
    })
}

fn extract_value(row: &PgRow, idx: usize) -> Value {
    let type_name = row.columns()[idx].type_info().name().to_ascii_uppercase();
    match type_name.as_str() {
        "BOOL" => row.try_get::<bool, _>(idx).map(Value::Bool).unwrap_or(Value::Null),
        "INT2" => row
            .try_get::<i16, _>(idx)
            .map(|v| Value::Int(v as i64))
            .unwrap_or(Value::Null),
        "INT4" => row
            .try_get::<i32, _>(idx)
            .map(|v| Value::Int(v as i64))
            .unwrap_or(Value::Null),
        "INT8" => row.try_get::<i64, _>(idx).map(Value::Int).unwrap_or(Value::Null),
        "FLOAT4" => row
            .try_get::<f32, _>(idx)
            .map(|v| Value::Float(v as f64))
            .unwrap_or(Value::Null),
        "FLOAT8" => row.try_get::<f64, _>(idx).map(Value::Float).unwrap_or(Value::Null),
        "NUMERIC" => row
            .try_get::<rust_decimal::Decimal, _>(idx)
            .map(Value::Decimal)
            .unwrap_or(Value::Null),
        "DATE" => row
            .try_get::<chrono::NaiveDate, _>(idx)
            .map(Value::Date)
            .unwrap_or(Value::Null),
        "TIME" => row
            .try_get::<chrono::NaiveTime, _>(idx)
            .map(Value::Time)
            .unwrap_or(Value::Null),
        "TIMESTAMP" => row
            .try_get::<chrono::NaiveDateTime, _>(idx)
            .map(Value::DateTime)
            .unwrap_or(Value::Null),
        "TIMESTAMPTZ" => row
            .try_get::<chrono::DateTime<chrono::Utc>, _>(idx)
            .map(Value::TimestampTz)
            .unwrap_or(Value::Null),
        "UUID" => row
            .try_get::<uuid::Uuid, _>(idx)
            .map(Value::Uuid)
            .unwrap_or(Value::Null),
        "JSON" | "JSONB" => row
            .try_get::<serde_json::Value, _>(idx)
            .map(Value::Json)
            .unwrap_or(Value::Null),
        "BYTEA" => row.try_get::<Vec<u8>, _>(idx).map(Value::Bytes).unwrap_or(Value::Null),
        _ => row.try_get::<String, _>(idx).map(Value::Text).unwrap_or(Value::Null),
    }
}

/// Bind a positional parameter list to a sqlx Postgres query in the
/// same order as the `params` slice. Centralised here so
/// `execute_params` and `execute_in_transaction` produce identical
/// bindings without duplicating the variant match.
fn bind_pg_params<'q>(
    mut q: sqlx::query::Query<'q, Postgres, sqlx::postgres::PgArguments>,
    params: &'q [Value],
) -> sqlx::query::Query<'q, Postgres, sqlx::postgres::PgArguments> {
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
            Value::Uuid(u) => q.bind(*u),
            Value::Json(j) => q.bind(j.clone()),
        };
    }
    q
}

fn quote_ident(name: &str) -> String {
    format!("\"{}\"", name.replace('"', "\"\""))
}

fn qualified(schema: Option<&str>, table: &str) -> String {
    match schema {
        Some(s) => format!("{}.{}", quote_ident(s), quote_ident(table)),
        None => quote_ident(table),
    }
}

fn map_sqlx_error(err: sqlx::Error) -> DriverError {
    use sqlx::Error::*;
    match err {
        Database(e) => DriverError::Query {
            message: e.message().to_string(),
            sqlstate: e.code().map(|c| c.to_string()),
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
    fn map_io_refused_returns_connection_refused() {
        let err = sqlx::Error::Io(std::io::Error::from(std::io::ErrorKind::ConnectionRefused));
        assert!(matches!(map_sqlx_error(err), DriverError::ConnectionRefused));
    }

    #[test]
    fn driver_metadata() {
        let d = PgDriver;
        assert_eq!(d.id(), "postgres");
        assert_eq!(d.default_port(), 5432);
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
}
