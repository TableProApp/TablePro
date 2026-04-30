use async_trait::async_trait;
use secrecy::SecretString;

use crate::error::DriverError;
use crate::query::{ColumnInfo, ExecResult, ForeignKeyInfo, IndexInfo, QueryResult, TableInfo, Value};

#[derive(Debug, Clone)]
pub struct ConnectOptions {
    pub host: String,
    pub port: u16,
    pub database: String,
    pub username: String,
    pub password: SecretString,
    pub use_tls: bool,
}

impl Default for ConnectOptions {
    fn default() -> Self {
        Self {
            host: "localhost".to_string(),
            port: 0,
            database: String::new(),
            username: String::new(),
            password: SecretString::new(String::new().into()),
            use_tls: false,
        }
    }
}

#[async_trait]
pub trait Connection: Send + Sync {
    async fn list_tables(&self) -> Result<Vec<TableInfo>, DriverError>;
    async fn fetch_columns(&self, schema: Option<&str>, table: &str) -> Result<Vec<ColumnInfo>, DriverError>;
    async fn fetch_rows(
        &self,
        schema: Option<&str>,
        table: &str,
        offset: u64,
        limit: u64,
    ) -> Result<QueryResult, DriverError>;
    async fn query(&self, sql: &str) -> Result<QueryResult, DriverError>;
    /// Parameterised SELECT. Bound `Value`s are passed through to the
    /// driver's prepare/bind path (sqlx::query::bind for the built-in
    /// drivers). Default impl delegates to `query` when params is
    /// empty, so legacy callers compile unchanged; drivers that
    /// support real parameter binding override.
    async fn query_params(&self, sql: &str, params: &[Value]) -> Result<QueryResult, DriverError> {
        if params.is_empty() {
            self.query(sql).await
        } else {
            Err(DriverError::Internal(
                "query_params is not implemented for this driver".into(),
            ))
        }
    }
    async fn execute(&self, sql: &str) -> Result<ExecResult, DriverError>;
    async fn execute_params(&self, sql: &str, params: &[Value]) -> Result<ExecResult, DriverError>;
    /// Run a sequence of parameterised statements inside a single
    /// database transaction. Rolls back automatically if any
    /// statement errors; returns `DriverError::Transaction` with the
    /// failing statement's index. Returns one `rows_affected` value
    /// per successful statement, in order. Used by the inline-edit
    /// changeset Save flow so all pending row inserts / updates /
    /// deletes commit atomically.
    async fn execute_in_transaction(&self, statements: &[(String, Vec<Value>)]) -> Result<Vec<u64>, DriverError>;
    /// Indexes defined on `table`. Implementations may include the
    /// implicit primary-key index with `primary = true` so the UI can
    /// render it as read-only. Default returns empty so existing
    /// drivers compile before they're filled in.
    async fn fetch_indexes(&self, _schema: Option<&str>, _table: &str) -> Result<Vec<IndexInfo>, DriverError> {
        Ok(Vec::new())
    }
    /// Foreign-key constraints declared on `table`. Default returns
    /// empty for the same reason as `fetch_indexes`.
    async fn fetch_foreign_keys(
        &self,
        _schema: Option<&str>,
        _table: &str,
    ) -> Result<Vec<ForeignKeyInfo>, DriverError> {
        Ok(Vec::new())
    }
    async fn ping(&self) -> Result<(), DriverError>;
    async fn close(self: Box<Self>) -> Result<(), DriverError>;
}
