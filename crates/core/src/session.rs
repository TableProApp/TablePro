use async_trait::async_trait;

use crate::error::DriverError;
use crate::operation::OperationControl;
use crate::query::{QueryCursorId, QueryCursorPage, QueryResult, QueryResultBatch, Value};

#[async_trait]
pub trait Session: Send {
    async fn query_params_controlled(
        &mut self,
        sql: &str,
        params: &[Value],
        control: &OperationControl,
    ) -> Result<QueryResult, DriverError>;

    async fn query_result_sets_params_controlled(
        &mut self,
        sql: &str,
        params: &[Value],
        control: &OperationControl,
    ) -> Result<QueryResultBatch, DriverError> {
        self.query_params_controlled(sql, params, control)
            .await
            .map(QueryResultBatch::single)
    }

    async fn open_query_cursor_controlled(
        &mut self,
        _sql: &str,
        _params: &[Value],
        _control: &OperationControl,
    ) -> Result<QueryCursorId, DriverError> {
        Err(DriverError::Unsupported("forward-only query cursors".into()))
    }

    async fn fetch_query_cursor_page_controlled(
        &mut self,
        _cursor_id: QueryCursorId,
        _control: &OperationControl,
    ) -> Result<QueryCursorPage, DriverError> {
        Err(DriverError::Unsupported("forward-only query cursors".into()))
    }

    async fn close_query_cursor_controlled(
        &mut self,
        _cursor_id: QueryCursorId,
        _control: &OperationControl,
    ) -> Result<(), DriverError> {
        Err(DriverError::Unsupported("forward-only query cursors".into()))
    }

    fn is_usable(&self) -> bool;

    fn transaction_open(&self) -> bool {
        false
    }

    async fn close(self: Box<Self>) -> Result<(), DriverError>;
}

#[cfg(test)]
mod tests {
    use super::*;

    struct SessionWithoutCursor;

    #[async_trait]
    impl Session for SessionWithoutCursor {
        async fn query_params_controlled(
            &mut self,
            _sql: &str,
            _params: &[Value],
            _control: &OperationControl,
        ) -> Result<QueryResult, DriverError> {
            Err(DriverError::Unsupported("query".into()))
        }

        fn is_usable(&self) -> bool {
            true
        }

        async fn close(self: Box<Self>) -> Result<(), DriverError> {
            Ok(())
        }
    }

    #[tokio::test]
    async fn session_without_cursor_support_returns_a_typed_unsupported_error() {
        let mut session = SessionWithoutCursor;
        let result = session
            .open_query_cursor_controlled(
                "SELECT 1",
                &[],
                &OperationControl::with_timeout(std::time::Duration::from_secs(1)),
            )
            .await;

        assert!(matches!(result, Err(DriverError::Unsupported(_))), "{result:?}");

        let result = session
            .fetch_query_cursor_page_controlled(
                QueryCursorId::new(),
                &OperationControl::with_timeout(std::time::Duration::from_secs(1)),
            )
            .await;
        assert!(matches!(result, Err(DriverError::Unsupported(_))), "{result:?}");

        let result = session
            .close_query_cursor_controlled(
                QueryCursorId::new(),
                &OperationControl::with_timeout(std::time::Duration::from_secs(1)),
            )
            .await;
        assert!(matches!(result, Err(DriverError::Unsupported(_))), "{result:?}");
    }

    struct SingleResultSession;

    #[async_trait]
    impl Session for SingleResultSession {
        async fn query_params_controlled(
            &mut self,
            _sql: &str,
            _params: &[Value],
            _control: &OperationControl,
        ) -> Result<QueryResult, DriverError> {
            Ok(QueryResult {
                columns: Vec::new(),
                rows: vec![vec![Value::Int(1)]],
                truncated: true,
            })
        }

        fn is_usable(&self) -> bool {
            true
        }

        async fn close(self: Box<Self>) -> Result<(), DriverError> {
            Ok(())
        }
    }

    #[tokio::test]
    async fn a_session_without_multiple_result_sets_returns_its_single_result_as_a_batch() {
        let mut session = SingleResultSession;
        let batch = session
            .query_result_sets_params_controlled(
                "SELECT 1",
                &[],
                &OperationControl::with_timeout(std::time::Duration::from_secs(1)),
            )
            .await
            .expect("batch");
        assert_eq!(batch.result_sets.len(), 1);
        assert_eq!(batch.result_sets[0].rows, vec![vec![Value::Int(1)]]);
        assert!(batch.truncated);
    }
}
