use tablepro_core::{ConnectOptions, DatabaseDriver};
use tokio_util::sync::CancellationToken;

use crate::{
    SshEnvironment, SshRoute, TransportError, Tunnel, audit_client, open_tunnel_with, record_transport_attempt,
};

pub async fn open_tool_endpoint(
    driver: &dyn DatabaseDriver,
    mut opts: ConnectOptions,
    ssh: Option<SshRoute>,
    environment: &SshEnvironment,
    cancellation: CancellationToken,
) -> Result<(ConnectOptions, Option<Tunnel>), TransportError> {
    crate::validate_client_tls_auth(driver, &opts)?;
    crate::validate_local_socket(&opts, driver, ssh.is_some())?;
    opts.forwarded_socket_dir = None;
    let Some(route) = ssh else {
        return Ok((opts, None));
    };
    let client = audit_client(Some(&route));
    let started = std::time::Instant::now();
    let result = tokio::select! {
        biased;
        () = cancellation.cancelled() => Err(TransportError::Cancelled),
        result = open_tunnel_with(&mut opts, route, environment, None, cancellation.clone()) => result,
    };
    if let Err(error) = record_transport_attempt(environment, client, started, &result).await {
        drop(result);
        return Err(error);
    }
    Ok((opts, Some(result?)))
}
