#![allow(clippy::unwrap_used, clippy::expect_used, clippy::panic)]

use std::path::PathBuf;
use std::sync::{Arc, Mutex};

use async_trait::async_trait;
use drivers_postgres::PgDriver;
use secrecy::SecretString;
use tablepro_app_services::database_backup::{BackupContext, BackupJob, run_backup_job};
use tablepro_core::{ConnectOptions, DatabaseDriver, DriverError, Environment, OperationControl, TlsConfig};
use tablepro_dump::ClientTool;
use tablepro_policy::{
    AuditError, AuditEvent, AuditOperationClass, AuditRecordPhase, AuditSink, AuditState, AuditTerminalStatus,
    AutoApproveSink, GuardContext, PolicyConfig, PolicyGuard, Principal,
};
use tablepro_ssh::UnknownHostKey;
use tablepro_transport::SshEnvironment;
use testcontainers::core::{CmdWaitFor, ExecCommand};
use testcontainers::{ContainerAsync, ImageExt};
use testcontainers_modules::postgres::Postgres;
use testcontainers_modules::testcontainers::runners::AsyncRunner;
use tokio_util::sync::CancellationToken;
use uuid::Uuid;

#[derive(Default)]
struct RecordingAudit(Mutex<Vec<AuditEvent>>);

#[async_trait]
impl AuditSink for RecordingAudit {
    async fn record(&self, event: AuditEvent) -> Result<(), AuditError> {
        self.0.lock().expect("audit events").push(event);
        Ok(())
    }
}

async fn psql(container: &ContainerAsync<Postgres>, sql: &str) -> String {
    let mut exec = container
        .exec(
            ExecCommand::new(["psql", "-v", "ON_ERROR_STOP=1", "-tA", "-U", "postgres", "-c", sql])
                .with_cmd_ready_condition(CmdWaitFor::exit_code(0)),
        )
        .await
        .expect("psql");
    String::from_utf8(exec.stdout_to_vec().await.expect("psql output")).unwrap()
}

async fn tool(name: &str, variable: &str) -> ClientTool {
    let configured = std::env::var_os(variable).map(PathBuf::from);
    ClientTool::locate(name, configured.as_deref())
        .await
        .unwrap_or_else(|error| panic!("{name} from {variable} or the host: {error}"))
}

fn guard(
    connection: Arc<dyn tablepro_core::Connection>,
    principal: Principal,
    audit: Arc<RecordingAudit>,
) -> PolicyGuard {
    PolicyGuard::new(
        connection,
        GuardContext {
            connection_id: Uuid::new_v4(),
            connection_name: "backup test".into(),
            driver_id: "postgres".into(),
            environment: Environment::Local,
            read_only: false,
            principal,
            policy: Arc::new(PolicyConfig::default()),
            approval: Arc::new(AutoApproveSink),
            audit,
            audit_state: Arc::new(AuditState::new()),
        },
    )
}

async fn run(
    guard: &PolicyGuard,
    tool: &ClientTool,
    options: &ConnectOptions,
    job: BackupJob,
) -> Result<(), DriverError> {
    let environment = SshEnvironment::builtin(UnknownHostKey::Refuse);
    let runtime = tempfile::tempdir().unwrap();
    let context = BackupContext {
        guard,
        tool,
        options: options.clone(),
        ssh: None,
        environment: &environment,
        server_major: 18,
        runtime_dir: runtime.path(),
    };
    let control = OperationControl::new(CancellationToken::new(), None);
    run_backup_job(context, job, &control).await
}

#[tokio::test]
#[ignore = "requires Docker; run scripts/test-pg-dump.sh"]
async fn a_guarded_backup_and_restore_bring_back_the_rows_and_are_audited() {
    let container = Postgres::default()
        .with_tag("18-alpine")
        .start()
        .await
        .expect("start postgres container");
    psql(
        &container,
        "CREATE TABLE items (id int PRIMARY KEY, name text); INSERT INTO items VALUES (1, 'one'), (2, 'two');",
    )
    .await;
    let options = ConnectOptions {
        host: container.get_host().await.expect("host").to_string(),
        port: container.get_host_port_ipv4(5432).await.expect("port"),
        database: "postgres".into(),
        username: "postgres".into(),
        password: SecretString::from("postgres"),
        tls: TlsConfig::disabled(),
        ..Default::default()
    };
    let connection: Arc<dyn tablepro_core::Connection> =
        Arc::from(PgDriver.connect(options.clone()).await.expect("connect"));
    let audit = Arc::new(RecordingAudit::default());
    let human = guard(connection.clone(), Principal::human_gui(), audit.clone());
    let dir = tempfile::tempdir().unwrap();
    let archive = dir.path().join("postgres.dump");

    let pg_dump = tool("pg_dump", "TABLEPRO_TEST_PG_DUMP").await;
    run(
        &human,
        &pg_dump,
        &options,
        BackupJob::Backup {
            output: archive.clone(),
        },
    )
    .await
    .expect("backup");
    psql(
        &container,
        "DELETE FROM items WHERE id = 2; INSERT INTO items VALUES (9, 'later');",
    )
    .await;
    let pg_restore = tool("pg_restore", "TABLEPRO_TEST_PG_RESTORE").await;
    run(
        &human,
        &pg_restore,
        &options,
        BackupJob::Restore { input: archive.clone() },
    )
    .await
    .expect("restore");

    let rows = psql(
        &container,
        "SELECT string_agg(id || '=' || name, ';' ORDER BY id) FROM items",
    )
    .await;
    assert_eq!(rows.trim(), "1=one;2=two");
    let outcomes: Vec<_> = audit
        .0
        .lock()
        .expect("audit events")
        .iter()
        .filter(|event| event.operation_class == AuditOperationClass::Administrative)
        .map(|event| (event.phase, event.terminal_status))
        .collect();
    assert_eq!(
        outcomes,
        [
            (AuditRecordPhase::Intent, AuditTerminalStatus::Pending),
            (AuditRecordPhase::Outcome, AuditTerminalStatus::Succeeded),
            (AuditRecordPhase::Intent, AuditTerminalStatus::Pending),
            (AuditRecordPhase::Outcome, AuditTerminalStatus::Succeeded),
        ]
    );

    let agent = Principal::Agent {
        token: "token".into(),
        client: None,
        model: None,
    };
    let refused = guard(connection, agent, Arc::new(RecordingAudit::default()));
    let error = run(&refused, &pg_restore, &options, BackupJob::Restore { input: archive })
        .await
        .expect_err("agents cannot restore");
    assert!(matches!(error, DriverError::PolicyDenied(_)), "{error:?}");
}
