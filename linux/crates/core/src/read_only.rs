use async_trait::async_trait;

use crate::connection::Connection;
use crate::error::DriverError;
use crate::query::{ColumnInfo, ExecResult, QueryResult, TableInfo, Value};

pub struct ReadOnlyConnection {
    inner: Box<dyn Connection>,
}

impl ReadOnlyConnection {
    pub fn wrap(inner: Box<dyn Connection>) -> Box<dyn Connection> {
        Box::new(Self { inner })
    }
}

#[async_trait]
impl Connection for ReadOnlyConnection {
    async fn list_tables(&self) -> Result<Vec<TableInfo>, DriverError> {
        self.inner.list_tables().await
    }

    async fn fetch_columns(&self, schema: Option<&str>, table: &str) -> Result<Vec<ColumnInfo>, DriverError> {
        self.inner.fetch_columns(schema, table).await
    }

    async fn fetch_rows(
        &self,
        schema: Option<&str>,
        table: &str,
        offset: u64,
        limit: u64,
    ) -> Result<QueryResult, DriverError> {
        self.inner.fetch_rows(schema, table, offset, limit).await
    }

    async fn query(&self, sql: &str) -> Result<QueryResult, DriverError> {
        self.inner.query(sql).await
    }

    async fn execute(&self, _sql: &str) -> Result<ExecResult, DriverError> {
        Err(DriverError::ReadOnly)
    }

    async fn execute_params(&self, _sql: &str, _params: &[Value]) -> Result<ExecResult, DriverError> {
        Err(DriverError::ReadOnly)
    }

    async fn execute_in_transaction(&self, _statements: &[(String, Vec<Value>)]) -> Result<Vec<u64>, DriverError> {
        Err(DriverError::ReadOnly)
    }

    async fn ping(&self) -> Result<(), DriverError> {
        self.inner.ping().await
    }

    async fn close(self: Box<Self>) -> Result<(), DriverError> {
        self.inner.close().await
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::Mutex;

    struct FakeConn {
        list_calls: Mutex<u32>,
        execute_calls: Mutex<u32>,
    }

    #[async_trait]
    impl Connection for FakeConn {
        async fn list_tables(&self) -> Result<Vec<TableInfo>, DriverError> {
            *self.list_calls.lock().unwrap() += 1;
            Ok(vec![TableInfo {
                schema: None,
                name: "t".into(),
            }])
        }
        async fn fetch_columns(&self, _: Option<&str>, _: &str) -> Result<Vec<ColumnInfo>, DriverError> {
            Ok(vec![])
        }
        async fn fetch_rows(&self, _: Option<&str>, _: &str, _: u64, _: u64) -> Result<QueryResult, DriverError> {
            Ok(QueryResult {
                columns: vec![],
                rows: vec![],
                truncated: false,
            })
        }
        async fn query(&self, _: &str) -> Result<QueryResult, DriverError> {
            Ok(QueryResult {
                columns: vec![],
                rows: vec![],
                truncated: false,
            })
        }
        async fn execute(&self, _: &str) -> Result<ExecResult, DriverError> {
            *self.execute_calls.lock().unwrap() += 1;
            Ok(ExecResult { rows_affected: 1 })
        }
        async fn execute_params(&self, _: &str, _: &[Value]) -> Result<ExecResult, DriverError> {
            *self.execute_calls.lock().unwrap() += 1;
            Ok(ExecResult { rows_affected: 1 })
        }
        async fn execute_in_transaction(&self, _: &[(String, Vec<Value>)]) -> Result<Vec<u64>, DriverError> {
            *self.execute_calls.lock().unwrap() += 1;
            Ok(vec![])
        }
        async fn ping(&self) -> Result<(), DriverError> {
            Ok(())
        }
        async fn close(self: Box<Self>) -> Result<(), DriverError> {
            Ok(())
        }
    }

    #[tokio::test]
    async fn reads_pass_through() {
        let inner = Box::new(FakeConn {
            list_calls: Mutex::new(0),
            execute_calls: Mutex::new(0),
        });
        let wrapped = ReadOnlyConnection::wrap(inner);
        let tables = wrapped.list_tables().await.unwrap();
        assert_eq!(tables.len(), 1);
    }

    #[tokio::test]
    async fn execute_returns_read_only_error() {
        let inner = Box::new(FakeConn {
            list_calls: Mutex::new(0),
            execute_calls: Mutex::new(0),
        });
        let wrapped = ReadOnlyConnection::wrap(inner);
        let err = wrapped.execute("DELETE FROM t").await.unwrap_err();
        assert!(matches!(err, DriverError::ReadOnly));
    }

    #[tokio::test]
    async fn execute_params_returns_read_only_error() {
        let inner = Box::new(FakeConn {
            list_calls: Mutex::new(0),
            execute_calls: Mutex::new(0),
        });
        let wrapped = ReadOnlyConnection::wrap(inner);
        let err = wrapped
            .execute_params("UPDATE t SET x = ?", &[Value::Int(1)])
            .await
            .unwrap_err();
        assert!(matches!(err, DriverError::ReadOnly));
    }
}
