use async_trait::async_trait;

use crate::error::DriverError;
use crate::operation::OperationControl;
use crate::query::{QueryResult, Value};

#[async_trait]
pub trait Session: Send {
    async fn query_params_controlled(
        &mut self,
        sql: &str,
        params: &[Value],
        control: &OperationControl,
    ) -> Result<QueryResult, DriverError>;

    fn is_usable(&self) -> bool;

    fn transaction_open(&self) -> bool {
        false
    }

    async fn close(self: Box<Self>) -> Result<(), DriverError>;
}
