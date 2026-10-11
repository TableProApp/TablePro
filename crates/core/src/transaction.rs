use async_trait::async_trait;

use crate::error::DriverError;
use crate::operation::{OperationControl, run_controlled};
use crate::query::{ExecResult, QueryResult, Value};

/// Interactive transaction handle. Distinct from
/// [`Connection::execute_in_transaction`], which is all-or-nothing with
/// no pause for preview. Agent write preview needs begin → execute →
/// report rows → commit / rollback.
#[async_trait]
pub trait Transaction: Send {
    async fn query(&mut self, sql: &str) -> Result<QueryResult, DriverError>;

    async fn query_controlled(&mut self, sql: &str, control: &OperationControl) -> Result<QueryResult, DriverError> {
        run_controlled(self.query(sql), control).await
    }

    async fn query_params(&mut self, sql: &str, params: &[Value]) -> Result<QueryResult, DriverError> {
        if params.is_empty() {
            self.query(sql).await
        } else {
            Err(DriverError::Unsupported(
                "query_params is not implemented for this transaction".into(),
            ))
        }
    }

    async fn query_params_controlled(
        &mut self,
        sql: &str,
        params: &[Value],
        control: &OperationControl,
    ) -> Result<QueryResult, DriverError> {
        run_controlled(self.query_params(sql, params), control).await
    }

    async fn execute(&mut self, sql: &str) -> Result<ExecResult, DriverError>;

    async fn execute_controlled(&mut self, sql: &str, control: &OperationControl) -> Result<ExecResult, DriverError> {
        run_controlled(self.execute(sql), control).await
    }

    async fn execute_params(&mut self, sql: &str, params: &[Value]) -> Result<ExecResult, DriverError> {
        if params.is_empty() {
            self.execute(sql).await
        } else {
            Err(DriverError::Unsupported(
                "execute_params is not implemented for this transaction".into(),
            ))
        }
    }

    async fn execute_params_controlled(
        &mut self,
        sql: &str,
        params: &[Value],
        control: &OperationControl,
    ) -> Result<ExecResult, DriverError> {
        run_controlled(self.execute_params(sql, params), control).await
    }

    async fn commit(self: Box<Self>) -> Result<(), DriverError>;
    async fn rollback(self: Box<Self>) -> Result<(), DriverError>;

    async fn rollback_controlled(self: Box<Self>, control: &OperationControl) -> Result<(), DriverError> {
        run_controlled(self.rollback(), control).await
    }
}
