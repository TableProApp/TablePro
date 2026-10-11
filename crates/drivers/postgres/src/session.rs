use async_trait::async_trait;
use sqlx::pool::PoolConnection;
use sqlx::postgres::{PgConnectOptions, PgPoolOptions};
use sqlx::{Pool, Postgres};
use tablepro_core::{DriverError, OperationControl, QueryResult, Value, check_pre_dispatch};

use crate::{CONTROL_SETUP_TIMEOUT, backend_pid, controlled_query, map_sqlx_error};

pub(crate) struct PgSession {
    connection: Option<PoolConnection<Postgres>>,
    pool: Pool<Postgres>,
    cancellation_pool: Pool<Postgres>,
    backend_pid: i32,
}

pub(crate) async fn open(
    options: &PgConnectOptions,
    cancellation_pool: Pool<Postgres>,
) -> Result<Box<dyn tablepro_core::Session>, DriverError> {
    let pool = PgPoolOptions::new()
        .max_connections(1)
        .acquire_timeout(CONTROL_SETUP_TIMEOUT)
        .connect_lazy_with(options.clone());
    let mut connection = tokio::time::timeout(CONTROL_SETUP_TIMEOUT, pool.acquire())
        .await
        .map_err(|_| DriverError::TimedOut)?
        .map_err(map_sqlx_error)?;
    connection.close_on_drop();
    let backend_pid = tokio::time::timeout(CONTROL_SETUP_TIMEOUT, backend_pid(&mut connection))
        .await
        .map_err(|_| DriverError::TimedOut)??;
    Ok(Box::new(PgSession {
        connection: Some(connection),
        pool,
        cancellation_pool,
        backend_pid,
    }))
}

#[async_trait]
impl tablepro_core::Session for PgSession {
    async fn query_params_controlled(
        &mut self,
        sql: &str,
        params: &[Value],
        control: &OperationControl,
    ) -> Result<QueryResult, DriverError> {
        check_pre_dispatch(control)?;
        let connection = self
            .connection
            .take()
            .ok_or_else(|| DriverError::Internal("the session's connection was lost".into()))?;
        let (connection, result) = controlled_query(
            connection,
            &self.cancellation_pool,
            self.backend_pid,
            sql,
            params,
            true,
            control,
        )
        .await;
        self.connection = connection;
        if matches!(result, Err(DriverError::Disconnected)) {
            // A lost backend also loses session-local state. Do not let the
            // single-slot pool silently replace it and masquerade as the same
            // session on the next statement.
            self.connection = None;
        }
        result
    }

    fn is_usable(&self) -> bool {
        self.connection.is_some()
    }

    async fn close(mut self: Box<Self>) -> Result<(), DriverError> {
        if let Some(connection) = self.connection.take() {
            let _ = connection.close().await;
        }
        self.pool.close().await;
        Ok(())
    }
}
