use std::str::FromStr;
use std::time::Duration;

use async_trait::async_trait;
use sqlx::sqlite::{SqliteConnectOptions, SqlitePoolOptions, SqliteRow};
use sqlx::{Column, Pool, Row, Sqlite, TypeInfo};

use futures::stream::StreamExt;

use tablepro_core::{
    ColumnInfo, ConnectOptions, Connection, DatabaseDriver, DriverError, ExecResult, MAX_QUERY_ROWS, QueryResult,
    TableInfo, Value,
};

pub struct SqliteDriver;

#[async_trait]
impl DatabaseDriver for SqliteDriver {
    fn id(&self) -> &'static str {
        "sqlite"
    }

    fn display_name(&self) -> &'static str {
        "SQLite"
    }

    fn default_port(&self) -> u16 {
        0
    }

    fn is_file_based(&self) -> bool {
        true
    }

    async fn connect(&self, opts: ConnectOptions) -> Result<Box<dyn Connection>, DriverError> {
        let url = if opts.database.is_empty() || opts.database == ":memory:" {
            "sqlite::memory:".to_string()
        } else {
            format!("sqlite:{}", opts.database)
        };
        let connect_opts = SqliteConnectOptions::from_str(&url)
            .map_err(map_sqlx_error)?
            .create_if_missing(true);
        let pool = SqlitePoolOptions::new()
            .max_connections(4)
            .acquire_timeout(Duration::from_secs(5))
            .connect_with(connect_opts)
            .await
            .map_err(map_sqlx_error)?;
        Ok(Box::new(SqliteConnection { pool }))
    }
}

struct SqliteConnection {
    pool: Pool<Sqlite>,
}

#[async_trait]
impl Connection for SqliteConnection {
    async fn list_tables(&self) -> Result<Vec<TableInfo>, DriverError> {
        let rows = sqlx::query(
            "SELECT name FROM sqlite_master
             WHERE type = 'table' AND name NOT LIKE 'sqlite_%'
             ORDER BY name",
        )
        .fetch_all(&self.pool)
        .await
        .map_err(map_sqlx_error)?;
        Ok(rows
            .into_iter()
            .map(|r| TableInfo {
                schema: None,
                name: r.get::<String, _>(0),
            })
            .collect())
    }

    async fn fetch_columns(&self, _schema: Option<&str>, table: &str) -> Result<Vec<ColumnInfo>, DriverError> {
        // PRAGMA table_xinfo includes the `hidden` column which we use
        // to detect virtual / generated columns. Falls back to
        // table_info on older SQLite (< 3.37) — both have the same
        // first 6 columns: cid, name, type, notnull, dflt_value, pk.
        let pragma_sql = format!("PRAGMA table_xinfo({})", quote_ident(table));
        let rows = sqlx::query(&pragma_sql)
            .fetch_all(&self.pool)
            .await
            .map_err(map_sqlx_error)?;

        // SQLite has no PRAGMA flag for AUTOINCREMENT — read the CREATE
        // TABLE DDL once and check whether the keyword appears. INTEGER
        // PRIMARY KEY (with or without AUTOINCREMENT) is a rowid alias
        // that auto-increments; we treat both as auto_increment.
        let ddl: Option<String> = sqlx::query_scalar("SELECT sql FROM sqlite_master WHERE type='table' AND name = ?")
            .bind(table)
            .fetch_optional(&self.pool)
            .await
            .map_err(map_sqlx_error)?;
        let ddl_upper = ddl.unwrap_or_default().to_ascii_uppercase();
        let table_has_autoincrement = ddl_upper.contains("AUTOINCREMENT");

        Ok(rows
            .into_iter()
            .map(|r| {
                let name: String = r.get(1);
                let data_type: String = r.get(2);
                let primary_key = r.get::<i64, _>(5) > 0;
                let dflt: Option<String> = r.try_get::<Option<String>, _>(4).unwrap_or(None);
                let hidden: i64 = r.try_get::<i64, _>(6).unwrap_or(0);
                // hidden=2 → STORED generated; hidden=3 → VIRTUAL generated.
                let is_generated = hidden == 2 || hidden == 3;
                let is_int_type = data_type.eq_ignore_ascii_case("INTEGER");
                let is_auto_increment = primary_key && is_int_type && (table_has_autoincrement || dflt.is_none());
                ColumnInfo {
                    name,
                    data_type,
                    nullable: r.get::<i64, _>(3) == 0,
                    primary_key,
                    is_auto_increment,
                    default_value: dflt,
                    is_generated,
                }
            })
            .collect())
    }

    async fn fetch_rows(
        &self,
        _schema: Option<&str>,
        table: &str,
        offset: u64,
        limit: u64,
    ) -> Result<QueryResult, DriverError> {
        let sql = format!("SELECT * FROM {} LIMIT {limit} OFFSET {offset}", quote_ident(table));
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
        let q = bind_sqlite_params(sqlx::query(sql), params);
        let res = q.execute(&self.pool).await.map_err(map_sqlx_error)?;
        Ok(ExecResult {
            rows_affected: res.rows_affected(),
        })
    }

    async fn execute_in_transaction(&self, statements: &[(String, Vec<Value>)]) -> Result<Vec<u64>, DriverError> {
        let mut tx = self.pool.begin().await.map_err(map_sqlx_error)?;
        let mut affected = Vec::with_capacity(statements.len());
        for (idx, (sql, params)) in statements.iter().enumerate() {
            let q = bind_sqlite_params(sqlx::query(sql), params);
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

async fn stream_into_result(pool: &Pool<Sqlite>, sql: &str, limit: usize) -> Result<QueryResult, DriverError> {
    let mut stream = sqlx::query(sql).fetch(pool);
    let mut collected: Vec<SqliteRow> = Vec::new();
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

fn extract_value(row: &SqliteRow, idx: usize) -> Value {
    let type_name = row.columns()[idx].type_info().name().to_ascii_uppercase();
    match type_name.as_str() {
        "INTEGER" => row.try_get::<i64, _>(idx).map(Value::Int).unwrap_or(Value::Null),
        "REAL" => row.try_get::<f64, _>(idx).map(Value::Float).unwrap_or(Value::Null),
        "BLOB" => row.try_get::<Vec<u8>, _>(idx).map(Value::Bytes).unwrap_or(Value::Null),
        "BOOLEAN" => row.try_get::<bool, _>(idx).map(Value::Bool).unwrap_or(Value::Null),
        "DATE" => row
            .try_get::<chrono::NaiveDate, _>(idx)
            .map(Value::Date)
            .or_else(|_| row.try_get::<String, _>(idx).map(Value::Text))
            .unwrap_or(Value::Null),
        "TIME" => row
            .try_get::<chrono::NaiveTime, _>(idx)
            .map(Value::Time)
            .or_else(|_| row.try_get::<String, _>(idx).map(Value::Text))
            .unwrap_or(Value::Null),
        "DATETIME" | "TIMESTAMP" => row
            .try_get::<chrono::NaiveDateTime, _>(idx)
            .map(Value::DateTime)
            .or_else(|_| row.try_get::<String, _>(idx).map(Value::Text))
            .unwrap_or(Value::Null),
        _ => row.try_get::<String, _>(idx).map(Value::Text).unwrap_or(Value::Null),
    }
}

fn bind_sqlite_params<'q>(
    mut q: sqlx::query::Query<'q, Sqlite, sqlx::sqlite::SqliteArguments<'q>>,
    params: &'q [Value],
) -> sqlx::query::Query<'q, Sqlite, sqlx::sqlite::SqliteArguments<'q>> {
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
            Value::Decimal(d) => q.bind(d.to_string()),
            Value::Uuid(u) => q.bind(u.to_string()),
            Value::Json(j) => q.bind(j.to_string()),
        };
    }
    q
}

fn quote_ident(name: &str) -> String {
    format!("\"{}\"", name.replace('"', "\"\""))
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
    use tempfile::TempDir;

    fn opts_for(path: &str) -> ConnectOptions {
        ConnectOptions {
            database: path.to_string(),
            ..Default::default()
        }
    }

    #[tokio::test]
    async fn driver_metadata() {
        let d = SqliteDriver;
        assert_eq!(d.id(), "sqlite");
        assert_eq!(d.display_name(), "SQLite");
    }

    #[tokio::test]
    async fn connect_create_and_list_tables() {
        let dir = TempDir::new().unwrap();
        let path = dir.path().join("test.db");
        let driver = SqliteDriver;
        let conn = driver.connect(opts_for(path.to_str().unwrap())).await.unwrap();
        conn.execute("CREATE TABLE foo (id INTEGER PRIMARY KEY, name TEXT)")
            .await
            .unwrap();
        conn.execute("INSERT INTO foo (name) VALUES ('a'), ('b'), ('c')")
            .await
            .unwrap();
        let tables = conn.list_tables().await.unwrap();
        assert_eq!(tables.len(), 1);
        assert_eq!(tables[0].name, "foo");
        let cols = conn.fetch_columns(None, "foo").await.unwrap();
        assert_eq!(cols.len(), 2);
        assert_eq!(cols[0].name, "id");
        assert!(cols[0].primary_key);
        let result = conn.fetch_rows(None, "foo", 0, 100).await.unwrap();
        assert_eq!(result.columns.len(), 2);
        assert_eq!(result.rows.len(), 3);
    }

    #[tokio::test]
    async fn fetch_rows_paginates() {
        let dir = TempDir::new().unwrap();
        let path = dir.path().join("page.db");
        let driver = SqliteDriver;
        let conn = driver.connect(opts_for(path.to_str().unwrap())).await.unwrap();
        conn.execute("CREATE TABLE n (i INTEGER)").await.unwrap();
        for i in 1..=10 {
            conn.execute(&format!("INSERT INTO n VALUES ({i})")).await.unwrap();
        }
        let page = conn.fetch_rows(None, "n", 5, 3).await.unwrap();
        assert_eq!(page.rows.len(), 3);
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

    #[tokio::test]
    async fn fetch_rows_handles_table_with_embedded_quote() {
        let dir = TempDir::new().unwrap();
        let path = dir.path().join("hostile.db");
        let driver = SqliteDriver;
        let conn = driver.connect(opts_for(path.to_str().unwrap())).await.unwrap();
        conn.execute("CREATE TABLE \"weird\"\"name\" (i INTEGER)")
            .await
            .unwrap();
        conn.execute("INSERT INTO \"weird\"\"name\" VALUES (1), (2)")
            .await
            .unwrap();
        let result = conn.fetch_rows(None, "weird\"name", 0, 100).await.unwrap();
        assert_eq!(result.rows.len(), 2);
    }
}
