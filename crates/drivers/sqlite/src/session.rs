use async_trait::async_trait;
use sqlx::pool::PoolConnection;
use sqlx::sqlite::{SqliteConnectOptions, SqlitePoolOptions};
use sqlx::{Connection as SqlxConnection, Pool, Sqlite};
use tablepro_core::{
    DriverError, MAX_QUERY_ROWS, OperationControl, QueryResult, Value, check_pre_dispatch, run_server_cancellable,
};

use crate::interrupt::InterruptHandle;
use crate::{confirms_cancellation, map_sqlx_error, params_into_result, request_interrupt};

const SESSION_SETUP_TIMEOUT: std::time::Duration = std::time::Duration::from_secs(10);

pub(crate) struct SqliteSession {
    connection: Option<PoolConnection<Sqlite>>,
    pool: Pool<Sqlite>,
}

pub(crate) async fn open(options: &SqliteConnectOptions) -> Result<Box<dyn tablepro_core::Session>, DriverError> {
    let pool = SqlitePoolOptions::new()
        .max_connections(1)
        .acquire_timeout(SESSION_SETUP_TIMEOUT)
        .connect_lazy_with(options.clone());
    let mut connection = tokio::time::timeout(SESSION_SETUP_TIMEOUT, pool.acquire())
        .await
        .map_err(|_| DriverError::TimedOut)?
        .map_err(map_sqlx_error)?;
    connection.close_on_drop();
    Ok(Box::new(SqliteSession {
        connection: Some(connection),
        pool,
    }))
}

#[async_trait]
impl tablepro_core::Session for SqliteSession {
    async fn query_params_controlled(
        &mut self,
        sql: &str,
        params: &[Value],
        control: &OperationControl,
    ) -> Result<QueryResult, DriverError> {
        check_pre_dispatch(control)?;
        let mut connection = self
            .connection
            .take()
            .ok_or_else(|| DriverError::Internal("the session's connection was lost".into()))?;
        let result = {
            let handle = InterruptHandle::of(&mut connection).await?;
            run_server_cancellable(
                params_into_result(&mut connection, sql, params, MAX_QUERY_ROWS),
                request_interrupt(&handle),
                confirms_cancellation,
                control,
            )
            .await
        };
        if matches!(result, Err(DriverError::OperationOutcomeUnknown { .. })) {
            drop(connection.detach());
        } else {
            self.connection = Some(connection);
        }
        result
    }

    fn is_usable(&self) -> bool {
        self.connection.is_some()
    }

    async fn close(mut self: Box<Self>) -> Result<(), DriverError> {
        if let Some(connection) = self.connection.take() {
            let _ = connection.detach().close().await;
        }
        self.pool.close().await;
        Ok(())
    }
}
