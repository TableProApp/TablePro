#![allow(clippy::unwrap_used, clippy::expect_used, clippy::panic)]

use std::sync::{Arc, Mutex};

use async_trait::async_trait;
use drivers_mssql::MssqlDriver;
use tablepro_core::{ConnectOptions, Connection, DatabaseDriver, DriverError, Environment};
use tablepro_policy::{
    AuditError, AuditEvent, AuditRecordPhase, AuditSink, AuditState, AuditTerminalStatus, AutoApproveSink,
    GuardContext, PolicyConfig, PolicyGuard, Principal, StatementClass, classify,
};
use testcontainers::runners::AsyncRunner;
use testcontainers_modules::mssql_server::MssqlServer;
use uuid::Uuid;

#[derive(Default)]
struct CapturingAudit(Mutex<Vec<AuditEvent>>);

#[async_trait]
impl AuditSink for CapturingAudit {
    async fn record(&self, event: AuditEvent) -> Result<(), AuditError> {
        self.0.lock().expect("audit event lock").push(event);
        Ok(())
    }
}

#[tokio::test]
#[ignore = "requires docker"]
async fn sql_server_batches_with_mutations_are_classified_and_denied_before_dispatch() {
    let container = MssqlServer::default().with_accept_eula().start().await.unwrap();
    let connection = MssqlDriver
        .connect(ConnectOptions {
            host: container.get_host().await.unwrap().to_string(),
            port: container.get_host_port_ipv4(1433).await.unwrap(),
            database: "master".into(),
            username: "sa".into(),
            password: secrecy::SecretString::new(MssqlServer::DEFAULT_SA_PASSWORD.to_string().into()),
            tls: tablepro_core::TlsConfig::disabled(),
            ..Default::default()
        })
        .await
        .unwrap();
    let connection: Arc<dyn Connection> = Arc::from(connection);
    connection
        .execute(
            "CREATE TABLE dbo.batch_target (id int PRIMARY KEY, value int NOT NULL); \
             CREATE TABLE dbo.batch_source (id int PRIMARY KEY, value int NOT NULL); \
             INSERT INTO dbo.batch_target VALUES (1, 10); \
             INSERT INTO dbo.batch_source VALUES (1, 99)",
        )
        .await
        .unwrap();

    let cases = [
        (
            "SELECT 1; UPDATE dbo.batch_target SET value = 20 WHERE id = 1",
            StatementClass::Update,
        ),
        ("SELECT 1; DROP TABLE dbo.batch_target", StatementClass::Ddl),
        (
            "MERGE dbo.batch_target AS target USING dbo.batch_source AS source \
             ON target.id = source.id WHEN MATCHED THEN UPDATE SET target.value = source.value;",
            StatementClass::Other,
        ),
        (
            "SELECT 1; MERGE dbo.batch_target AS target USING dbo.batch_source AS source \
             ON target.id = source.id WHEN MATCHED THEN UPDATE SET target.value = source.value;",
            StatementClass::Other,
        ),
    ];
    let audit = Arc::new(CapturingAudit::default());
    let guard = PolicyGuard::new(
        connection.clone(),
        GuardContext {
            connection_id: Uuid::new_v4(),
            connection_name: "SQL Server SEC-4 fixture".into(),
            driver_id: "mssql".into(),
            environment: Environment::Local,
            read_only: true,
            principal: Principal::human_gui(),
            policy: Arc::new(PolicyConfig::default()),
            approval: Arc::new(AutoApproveSink),
            audit: audit.clone(),
            audit_state: Arc::new(AuditState::new()),
        },
    );

    for &(sql, expected_class) in &cases {
        let facts = classify(sql, "mssql");
        assert_eq!(facts.class, expected_class, "classification for {sql}");
        assert!(facts.writes(), "batch must require write capability: {sql}");
        assert!(
            facts.is_multi_statement || sql.starts_with("MERGE"),
            "batch flag for {sql}"
        );
        assert_ne!(
            facts.class,
            StatementClass::Unparseable,
            "SQL Server syntax must parse: {sql}"
        );
        assert!(
            matches!(guard.query(sql).await, Err(DriverError::PolicyDenied(_))),
            "read-only guard must deny before dispatch: {sql}"
        );
        let state = connection
            .query(
                "SELECT CASE WHEN OBJECT_ID(N'dbo.batch_target') IS NULL THEN 0 ELSE 1 END, COUNT(*), MAX(value) \
                 FROM dbo.batch_target",
            )
            .await
            .expect("target remains queryable after denial");
        assert_eq!(
            state.rows,
            vec![vec![
                tablepro_core::Value::Int(1),
                tablepro_core::Value::Int(1),
                tablepro_core::Value::Int(10)
            ]]
        );
    }

    let outcomes = audit
        .0
        .lock()
        .expect("audit event lock")
        .iter()
        .filter(|event| event.phase == AuditRecordPhase::Outcome)
        .cloned()
        .collect::<Vec<_>>();
    assert_eq!(outcomes.len(), cases.len());
    assert!(
        outcomes
            .iter()
            .all(|event| event.terminal_status == AuditTerminalStatus::Denied)
    );
}
