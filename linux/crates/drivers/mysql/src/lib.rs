use std::time::Duration;

use async_trait::async_trait;
use secrecy::ExposeSecret;
use sqlx::mysql::{MySql, MySqlConnectOptions, MySqlPoolOptions, MySqlRow};
use sqlx::{Column, Pool, Row, TypeInfo};

use futures::stream::StreamExt;

use tablepro_core::{
    ColumnInfo, ConnectOptions, Connection, DatabaseDriver, DriverError, ExecResult, MAX_QUERY_ROWS, QueryResult,
    TableInfo, Value,
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
        let pool = MySqlPoolOptions::new()
            .max_connections(4)
            .acquire_timeout(Duration::from_secs(5))
            .connect_with(mysql_opts)
            .await
            .map_err(map_sqlx_error)?;
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
        let rows = sqlx::query(
            "SELECT CAST(column_name AS CHAR), CAST(data_type AS CHAR),
                    CAST(is_nullable AS CHAR), CAST(column_key AS CHAR),
                    CAST(extra AS CHAR), CAST(column_default AS CHAR),
                    CAST(generation_expression AS CHAR)
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
                let default_value: Option<String> = r.try_get::<Option<String>, _>(5).unwrap_or(None);
                let generation_expr: Option<String> = r.try_get::<Option<String>, _>(6).unwrap_or(None);
                ColumnInfo {
                    name: r.get::<String, _>(0),
                    data_type: r.get::<String, _>(1),
                    nullable: r.get::<String, _>(2) == "YES",
                    primary_key: r.get::<String, _>(3) == "PRI",
                    is_auto_increment: extra.contains("auto_increment"),
                    default_value,
                    is_generated: generation_expr.is_some() || extra.contains("generated"),
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

    async fn execute(&self, sql: &str) -> Result<ExecResult, DriverError> {
        let res = sqlx::query(sql).execute(&self.pool).await.map_err(map_sqlx_error)?;
        Ok(ExecResult {
            rows_affected: res.rows_affected(),
        })
    }

    async fn execute_params(&self, sql: &str, params: &[Value]) -> Result<ExecResult, DriverError> {
        let q = bind_mysql_params(sqlx::query(sql), params);
        let res = q.execute(&self.pool).await.map_err(map_sqlx_error)?;
        Ok(ExecResult {
            rows_affected: res.rows_affected(),
        })
    }

    async fn execute_in_transaction(&self, statements: &[(String, Vec<Value>)]) -> Result<Vec<u64>, DriverError> {
        let mut tx = self.pool.begin().await.map_err(map_sqlx_error)?;
        let mut affected = Vec::with_capacity(statements.len());
        for (idx, (sql, params)) in statements.iter().enumerate() {
            let q = bind_mysql_params(sqlx::query(sql), params);
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

async fn stream_into_result(pool: &Pool<MySql>, sql: &str, limit: usize) -> Result<QueryResult, DriverError> {
    let mut stream = sqlx::query(sql).fetch(pool);
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

fn extract_value(row: &MySqlRow, idx: usize) -> Value {
    let type_name = row.columns()[idx].type_info().name().to_ascii_uppercase();
    match type_name.as_str() {
        "TINYINT" | "SMALLINT" | "INT" | "MEDIUMINT" | "BIGINT" => {
            row.try_get::<i64, _>(idx).map(Value::Int).unwrap_or(Value::Null)
        }
        "FLOAT" | "DOUBLE" => row.try_get::<f64, _>(idx).map(Value::Float).unwrap_or(Value::Null),
        "DECIMAL" | "NUMERIC" => row
            .try_get::<rust_decimal::Decimal, _>(idx)
            .map(Value::Decimal)
            .unwrap_or(Value::Null),
        "BOOLEAN" => row.try_get::<bool, _>(idx).map(Value::Bool).unwrap_or(Value::Null),
        "DATE" => row
            .try_get::<chrono::NaiveDate, _>(idx)
            .map(Value::Date)
            .unwrap_or(Value::Null),
        "TIME" => row
            .try_get::<chrono::NaiveTime, _>(idx)
            .map(Value::Time)
            .unwrap_or(Value::Null),
        "DATETIME" => row
            .try_get::<chrono::NaiveDateTime, _>(idx)
            .map(Value::DateTime)
            .unwrap_or(Value::Null),
        "TIMESTAMP" => row
            .try_get::<chrono::DateTime<chrono::Utc>, _>(idx)
            .map(Value::TimestampTz)
            .unwrap_or(Value::Null),
        "JSON" => row
            .try_get::<serde_json::Value, _>(idx)
            .map(Value::Json)
            .unwrap_or(Value::Null),
        "BLOB" | "TINYBLOB" | "MEDIUMBLOB" | "LONGBLOB" | "VARBINARY" | "BINARY" => {
            row.try_get::<Vec<u8>, _>(idx).map(Value::Bytes).unwrap_or(Value::Null)
        }
        _ => row.try_get::<String, _>(idx).map(Value::Text).unwrap_or(Value::Null),
    }
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
    fn driver_metadata() {
        let d = MysqlDriver;
        assert_eq!(d.id(), "mysql");
        assert_eq!(d.display_name(), "MySQL");
        assert_eq!(d.default_port(), 3306);
    }

    #[test]
    fn map_io_refused_returns_connection_refused() {
        let err = sqlx::Error::Io(std::io::Error::from(std::io::ErrorKind::ConnectionRefused));
        assert!(matches!(map_sqlx_error(err), DriverError::ConnectionRefused));
    }

    #[test]
    fn quote_ident_doubles_embedded_backticks() {
        assert_eq!(quote_ident("users"), "`users`");
        assert_eq!(quote_ident("My Table"), "`My Table`");
        assert_eq!(quote_ident("evil`; DROP TABLE x; --"), "`evil``; DROP TABLE x; --`");
    }
}
