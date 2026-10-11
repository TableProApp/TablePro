#![allow(clippy::unwrap_used, clippy::expect_used, clippy::panic)]
use std::sync::{Arc, Mutex};
use std::time::Duration;

use async_trait::async_trait;
use drivers_postgres::PgDriver;
use tablepro_core::{ConnectOptions, Connection, DatabaseDriver, DriverError, Environment, OperationControl, Value};
use tablepro_policy::{
    AuditError, AuditEvent, AuditOperationClass, AuditRecordPhase, AuditSink, AuditState, AuditTerminalStatus,
    AuditTransactionOutcome, AutoApproveSink, GuardContext, PolicyConfig, PolicyGuard, Principal,
};
use testcontainers::ContainerAsync;
use testcontainers::ImageExt;
use testcontainers_modules::postgres::Postgres;
use testcontainers_modules::testcontainers::runners::AsyncRunner;
use tokio_util::sync::CancellationToken;
use uuid::Uuid;

struct CapturingAudit {
    events: Mutex<Vec<AuditEvent>>,
}

impl CapturingAudit {
    fn new() -> Self {
        Self {
            events: Mutex::new(Vec::new()),
        }
    }
}

#[async_trait]
impl AuditSink for CapturingAudit {
    async fn record(&self, event: AuditEvent) -> Result<(), AuditError> {
        self.events.lock().expect("event lock").push(event);
        Ok(())
    }
}

fn outcomes_of(audit: &CapturingAudit, class: AuditOperationClass) -> Vec<AuditEvent> {
    audit
        .events
        .lock()
        .expect("event lock")
        .iter()
        .filter(|event| event.operation_class == class && event.phase == AuditRecordPhase::Outcome)
        .cloned()
        .collect()
}

async fn start_pg() -> (ContainerAsync<Postgres>, ConnectOptions) {
    let container = Postgres::default()
        .with_tag("16-alpine")
        .start()
        .await
        .expect("start postgres container");
    let host = container.get_host().await.expect("host").to_string();
    let port = container.get_host_port_ipv4(5432).await.expect("port");
    let opts = ConnectOptions {
        host,
        port,
        database: "postgres".into(),
        username: "postgres".into(),
        password: secrecy::SecretString::new("postgres".to_string().into()),
        tls: tablepro_core::TlsConfig::disabled(),
        ..Default::default()
    };
    (container, opts)
}

async fn connect(opts: ConnectOptions) -> Box<dyn Connection> {
    PgDriver.connect(opts).await.expect("connect")
}

fn no_timeout() -> OperationControl {
    OperationControl::new(CancellationToken::new(), None)
}

fn guard_context(audit: Arc<CapturingAudit>, audit_state: Arc<AuditState>) -> GuardContext {
    GuardContext {
        connection_id: Uuid::nil(),
        connection_name: "policy-session-postgres-test".into(),
        driver_id: "postgres".into(),
        environment: Environment::Local,
        read_only: false,
        principal: Principal::human_gui(),
        policy: Arc::new(PolicyConfig::default()),
        approval: Arc::new(AutoApproveSink),
        audit,
        audit_state,
    }
}

async fn run(
    session: &mut Box<dyn tablepro_core::Session>,
    sql: &str,
) -> Result<tablepro_core::QueryResult, DriverError> {
    session.query_params_controlled(sql, &[], &no_timeout()).await
}

#[tokio::test]
#[ignore = "requires docker"]
async fn a_commit_on_a_server_aborted_postgres_transaction_is_audited_as_rolled_back() {
    let (_container, opts) = start_pg().await;
    let raw = connect(opts).await;
    raw.execute("CREATE TABLE d1_probe (id INT PRIMARY KEY)").await.unwrap();

    let audit = Arc::new(CapturingAudit::new());
    let audit_state = Arc::new(AuditState::new());
    let inner: Arc<dyn Connection> = Arc::from(raw);
    let guard = PolicyGuard::new(inner.clone(), guard_context(audit.clone(), audit_state.clone()));
    let mut session = guard.open_session().await.expect("open session");

    run(&mut session, "BEGIN").await.expect("begin");
    run(&mut session, "INSERT INTO d1_probe (id) VALUES (1)")
        .await
        .expect("first insert");
    let cancelled = session
        .query_params_controlled(
            "SELECT pg_sleep(5)",
            &[],
            &OperationControl::with_timeout(Duration::from_millis(300)),
        )
        .await;
    assert!(
        matches!(cancelled, Err(DriverError::TimedOut)),
        "the deadline must cancel the sleep server-side and abort the transaction: {cancelled:?}"
    );

    let commit = run(&mut session, "COMMIT").await;
    assert!(
        commit.is_ok(),
        "postgres accepts COMMIT on an aborted transaction and rolls back silently: {commit:?}"
    );
    session.close().await.expect("close");

    let commits = outcomes_of(&audit, AuditOperationClass::TransactionCommit);
    assert_eq!(commits.len(), 1);
    assert_eq!(
        commits[0].transaction_outcome,
        AuditTransactionOutcome::RolledBack,
        "the audit must record what postgres actually did, not what the client asked for"
    );
    assert_eq!(commits[0].terminal_status, AuditTerminalStatus::Succeeded);

    let after = inner
        .query("SELECT count(*)::bigint FROM d1_probe")
        .await
        .expect("verify row count");
    assert_eq!(after.rows, vec![vec![Value::Int(0)]]);
}

#[tokio::test]
#[ignore = "requires docker"]
async fn a_commit_failing_on_a_deferred_constraint_closes_the_batch() {
    let (_container, opts) = start_pg().await;
    let raw = connect(opts).await;
    raw.execute("CREATE TABLE d2_parent (id INT PRIMARY KEY)")
        .await
        .unwrap();
    raw.execute(
        "CREATE TABLE d2_child (id INT PRIMARY KEY, parent_id INT REFERENCES d2_parent(id) DEFERRABLE INITIALLY DEFERRED)",
    )
    .await
    .unwrap();

    let audit = Arc::new(CapturingAudit::new());
    let audit_state = Arc::new(AuditState::new());
    let inner: Arc<dyn Connection> = Arc::from(raw);
    let guard = PolicyGuard::new(inner.clone(), guard_context(audit.clone(), audit_state.clone()));
    let mut session = guard.open_session().await.expect("open session");

    run(&mut session, "BEGIN").await.expect("begin");
    run(&mut session, "INSERT INTO d2_child (id, parent_id) VALUES (1, 999)")
        .await
        .expect("insert passes until the deferred check runs");
    assert!(session.transaction_open());

    let commit = run(&mut session, "COMMIT").await;
    assert!(
        commit.is_err(),
        "the deferred foreign key must fail exactly at commit time"
    );
    assert!(
        !session.transaction_open(),
        "a definite commit failure must close the batch instead of leaving it open"
    );

    run(&mut session, "BEGIN")
        .await
        .expect("a fresh transaction must be startable after the closed batch");
    session.close().await.expect("close");

    let commits = outcomes_of(&audit, AuditOperationClass::TransactionCommit);
    assert_eq!(commits.len(), 1);
    assert_eq!(commits[0].terminal_status, AuditTerminalStatus::Failed);
    assert_eq!(commits[0].transaction_outcome, AuditTransactionOutcome::Failed);

    let after = inner
        .query("SELECT count(*)::bigint FROM d2_child")
        .await
        .expect("verify row count");
    assert_eq!(after.rows, vec![vec![Value::Int(0)]]);
}

#[tokio::test]
#[ignore = "requires docker"]
async fn closing_a_session_with_an_open_transaction_rolls_it_back_on_real_postgres() {
    let (_container, opts) = start_pg().await;
    let raw = connect(opts.clone()).await;
    raw.execute("CREATE TABLE d8_probe (id INT PRIMARY KEY, v INT)")
        .await
        .unwrap();
    raw.execute("INSERT INTO d8_probe (id, v) VALUES (1, 1)").await.unwrap();

    let audit = Arc::new(CapturingAudit::new());
    let audit_state = Arc::new(AuditState::new());
    let inner: Arc<dyn Connection> = Arc::from(raw);
    let guard = PolicyGuard::new(inner, guard_context(audit.clone(), audit_state.clone()));
    let mut session = guard.open_session().await.expect("open session");

    run(&mut session, "BEGIN").await.expect("begin");
    run(&mut session, "UPDATE d8_probe SET v = 2 WHERE id = 1")
        .await
        .expect("write");

    session.close().await.expect("close");

    let rollbacks = outcomes_of(&audit, AuditOperationClass::TransactionRollback);
    assert_eq!(rollbacks.len(), 1);
    assert_eq!(rollbacks[0].transaction_outcome, AuditTransactionOutcome::RolledBack);
    assert!(!audit_state.governed_writes_disabled());

    let fresh = connect(opts).await;
    let after = fresh
        .query("SELECT v FROM d8_probe WHERE id = 1")
        .await
        .expect("verify row on a fresh connection");
    assert_eq!(after.rows, vec![vec![Value::Int(1)]]);
}

#[tokio::test]
#[ignore = "requires docker"]
async fn a_read_only_repeatable_read_session_keeps_one_snapshot_across_queries() {
    let (_container, opts) = start_pg().await;
    let raw = connect(opts.clone()).await;
    raw.execute("CREATE TABLE snapshot_probe (id INT PRIMARY KEY)")
        .await
        .unwrap();
    raw.execute("INSERT INTO snapshot_probe VALUES (1)").await.unwrap();

    let audit = Arc::new(CapturingAudit::new());
    let audit_state = Arc::new(AuditState::new());
    let inner: Arc<dyn Connection> = Arc::from(raw);
    let guard = PolicyGuard::new(inner, guard_context(audit.clone(), audit_state));
    let mut session = guard.open_session().await.expect("open session");

    run(&mut session, "BEGIN ISOLATION LEVEL REPEATABLE READ READ ONLY")
        .await
        .expect("begin read snapshot");
    let before = run(&mut session, "SELECT count(*)::bigint FROM snapshot_probe")
        .await
        .expect("first snapshot read");
    assert_eq!(before.rows, vec![vec![Value::Int(1)]]);

    let writer = connect(opts).await;
    writer.execute("INSERT INTO snapshot_probe VALUES (2)").await.unwrap();

    let after = run(&mut session, "SELECT count(*)::bigint FROM snapshot_probe")
        .await
        .expect("second snapshot read");
    assert_eq!(after.rows, vec![vec![Value::Int(1)]]);
    run(&mut session, "ROLLBACK").await.expect("close snapshot");
    session.close().await.expect("close session");

    let reads = outcomes_of(&audit, AuditOperationClass::Read);
    assert_eq!(reads.len(), 3);
    assert_eq!(reads[0].terminal_status, AuditTerminalStatus::Succeeded);
}
