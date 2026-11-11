use std::sync::Arc;

use async_trait::async_trait;
use tablepro_core::{
    ByteLimitSink, CallOptions, DriverError, EditorSession, EditorSessionId, EditorSessionState, ResultSink,
    RunOptions, RunSummary, TransactionState, UserSql,
};

// Every app opens its editor sessions here, so none can run one without the run's byte limit.
pub(super) struct ByteLimitedEditor {
    inner: Arc<dyn EditorSession>,
}

impl ByteLimitedEditor {
    pub(super) fn wrap(inner: Arc<dyn EditorSession>) -> Arc<dyn EditorSession> {
        Arc::new(Self { inner })
    }
}

#[async_trait]
impl EditorSession for ByteLimitedEditor {
    fn id(&self) -> EditorSessionId {
        self.inner.id()
    }

    fn state(&self) -> EditorSessionState {
        self.inner.state()
    }

    async fn run(
        &self,
        sql: UserSql,
        options: RunOptions,
        sink: Box<dyn ResultSink>,
    ) -> Result<RunSummary, DriverError> {
        let limited = Box::new(ByteLimitSink::new(sink, options.byte_limit));
        self.inner.run(sql, options, limited).await
    }

    async fn transaction_state(&self, options: CallOptions) -> Result<TransactionState, DriverError> {
        self.inner.transaction_state(options).await
    }

    fn database(&self) -> Option<String> {
        self.inner.database()
    }

    async fn use_database(&self, database: &str, options: CallOptions) -> Result<(), DriverError> {
        self.inner.use_database(database, options).await
    }

    async fn close(&self) {
        self.inner.close().await;
    }
}
