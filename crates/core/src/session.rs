use async_trait::async_trait;

use crate::error::DriverError;
use crate::operation::OperationControl;
use crate::query::{QueryCursorId, QueryCursorPage, QueryResult, Value};

#[async_trait]
pub trait Session: Send {
    async fn query_params_controlled(
        &mut self,
        sql: &str,
        params: &[Value],
        control: &OperationControl,
    ) -> Result<QueryResult, DriverError>;

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
}
