use async_trait::async_trait;
use secrecy::SecretString;

use crate::error::DriverError;
use crate::query::{ColumnInfo, ExecResult, QueryResult, TableInfo, Value};

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
    async fn ping(&self) -> Result<(), DriverError>;
    async fn close(self: Box<Self>) -> Result<(), DriverError>;
}
