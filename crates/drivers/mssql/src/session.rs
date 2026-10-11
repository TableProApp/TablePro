use async_trait::async_trait;
use tablepro_core::{
    AuthMode, ConnectOptions, DriverError, MAX_QUERY_ROWS, OperationControl, QueryResult, Value, check_pre_dispatch,
    run_server_cancellable,
};

use crate::variant_guard::is_unsupported_result;
use crate::{CONNECT_TIMEOUT, MssqlClient, build_target, open_client, open_kerberos_client, run_batch, run_query};

pub(crate) struct MssqlSession {
    client: Option<MssqlClient>,
}

pub(crate) async fn open(options: &ConnectOptions) -> Result<Box<dyn tablepro_core::Session>, DriverError> {
    let target = build_target(options)?;
    let client = match options.auth_mode {
        AuthMode::Password => tokio::time::timeout(CONNECT_TIMEOUT, open_client(target))
            .await
            .map_err(|_| DriverError::ConnectionRefused)??,
        AuthMode::Kerberos => open_kerberos_client(target).await?,
    };
    Ok(Box::new(MssqlSession { client: Some(client) }))
}

#[async_trait]
impl tablepro_core::Session for MssqlSession {
    async fn query_params_controlled(
        &mut self,
        sql: &str,
        params: &[Value],
        control: &OperationControl,
    ) -> Result<QueryResult, DriverError> {
        check_pre_dispatch(control)?;
        let mut client = self
            .client
            .take()
            .ok_or_else(|| DriverError::Internal("the session's connection was lost".into()))?;
        let execution = async {
            match params.is_empty() {
                true => run_batch(&mut client, sql, MAX_QUERY_ROWS).await,
                false => run_query(&mut client, sql, params, MAX_QUERY_ROWS).await,
            }
        };
        let result = run_server_cancellable(execution, async { Ok(()) }, |_| false, control).await;
        if !matches!(
            result,
            Err(DriverError::OperationOutcomeUnknown { .. } | DriverError::Disconnected)
        ) && !result.as_ref().is_err_and(is_unsupported_result)
        {
            self.client = Some(client);
        }
        result
    }

    fn is_usable(&self) -> bool {
        self.client.is_some()
    }

    async fn close(mut self: Box<Self>) -> Result<(), DriverError> {
        if let Some(client) = self.client.take() {
            let _ = client.close().await;
        }
        Ok(())
    }
}
