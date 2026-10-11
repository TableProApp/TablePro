#![allow(clippy::unwrap_used, clippy::expect_used, clippy::panic)]
//! Real agent-provider coverage for saved PostgreSQL Unix sockets.
//!
//! Run through `scripts/test-postgres-socket.sh`.

use std::sync::Arc;

use tablepro_agentd::DaemonProvider;
use tablepro_core::{AuthMode, DriverRegistry, Environment, TlsMode, Value};
use tablepro_mcp::ConnectionProvider;
use tablepro_policy::{AuditState, DenyApprovalSink, PolicyConfig, Principal};
use tablepro_storage::{AuditJournal, SavedConnection, save_connections};
use uuid::Uuid;

#[tokio::test]
#[ignore = "requires scripts/test-postgres-socket.sh"]
async fn saved_socket_is_available_through_the_agent_provider() {
    let socket_dir = std::env::var("TABLEPRO_PG_SOCKET_DIR").expect("socket fixture directory");
    let saved = SavedConnection {
        id: Uuid::new_v4(),
        name: "Socket fixture".into(),
        driver_id: "postgres".into(),
        host: "localhost".into(),
        port: 5432,
        socket_dir: Some(socket_dir.into()),
        database: "postgres".into(),
        username: "postgres".into(),
        use_tls: false,
        tls_mode: Some(TlsMode::Disabled),
        tls_root_cert: None,
        tls_client_cert: None,
        tls_client_key: None,
        read_only: false,
        auth_mode: AuthMode::Password,
        environment: Environment::Local,
        ssh: None,
        last_opened_at: None,
        connect_timeout_secs: None,
        query_timeout_secs: None,
    };
    save_connections(std::slice::from_ref(&saved))
        .await
        .expect("save socket connection");

    let mut registry = DriverRegistry::new();
    registry.register(Arc::new(drivers_postgres::PgDriver));
    let journal_dir = tempfile::tempdir().expect("audit directory");
    let audit = AuditJournal::open_validated(journal_dir.path().join("audit.jsonl")).expect("audit journal");
    let provider = DaemonProvider::new(
        Arc::new(registry),
        Arc::new(PolicyConfig::default()),
        Arc::new(audit),
        Arc::new(AuditState::new()),
        Arc::new(DenyApprovalSink),
    );
    let connection = provider
        .connection(
            saved.id,
            Principal::Agent {
                token: "socket-test".into(),
                client: Some("integration".into()),
                model: None,
            },
        )
        .await
        .expect("agent provider connects through saved socket");

    let result = connection.query("SELECT 42").await.expect("agent read over socket");
    assert_eq!(result.rows, vec![vec![Value::Int(42)]]);
}
