use std::path::PathBuf;
use std::sync::Arc;

use super::*;

#[tokio::test]
async fn invalid_local_sockets_and_client_tls_are_refused() {
    let environment = audit_environment(Arc::new(RecordingAudit::default()), Arc::new(AuditState::new()));
    let mut socket = ConnectOptions {
        local_socket_path: Some(PathBuf::from("/missing/postgres.sock")),
        ..Default::default()
    };
    assert!(matches!(
        open_tool_endpoint(
            &SocketDriver,
            socket.clone(),
            None,
            &environment,
            tokio_util::sync::CancellationToken::new(),
        )
        .await,
        Err(TransportError::InvalidLocalSocket(_))
    ));
    socket.local_socket_path = None;
    socket.local_socket_dir = Some(PathBuf::from("/run/postgresql"));
    assert!(matches!(
        open_tool_endpoint(
            &SocketDriver,
            socket,
            Some(SshRoute::Builtin(Vec::new())),
            &environment,
            tokio_util::sync::CancellationToken::new(),
        )
        .await,
        Err(TransportError::LocalSocketWithSsh)
    ));
    let mut partial_tls = ConnectOptions::default();
    partial_tls.tls.client_cert = Some("client.pem".into());
    assert!(matches!(
        open_tool_endpoint(
            &HangingDriver,
            partial_tls,
            None,
            &environment,
            tokio_util::sync::CancellationToken::new(),
        )
        .await,
        Err(TransportError::Driver(DriverError::Unsupported(_)))
    ));
}
