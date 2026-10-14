//! A browse tab's pending edits saved to a real PostgreSQL, planned the
//! way the app plans them.

#![expect(
    clippy::expect_used,
    reason = "the setup helpers fail a test the way the test functions themselves do"
)]

use std::sync::Arc;
use std::time::Duration;

use drivers_postgres::PgDriver;
use secrecy::SecretString;
use tablepro_app::change_tracker::{RowKey, pk_identity};
use tablepro_app::tab_tracker_handle::TabTrackerHandle;
use tablepro_app::tracker_edit::TrackerEdit;
use tablepro_core::edit::CellInput;
use tablepro_core::meta::TableRef;
use tablepro_core::save::plan_save;
use tablepro_core::statement::{GuardedStatement, Statement, StatementBuilder};
use tablepro_core::{
    CallOptions, ConnectEnvironment, ConnectOptions, ConnectTarget, Connection, Credentials, DatabaseDriver,
    ForeignKeyMode, NetworkEndpoint, NetworkTarget, RowLimit, TlsConfig, Value, WorkspaceSettings, WriteBatch,
    WriteKind,
};
use tablepro_net::DirectTcpTransport;
use tablepro_test_fixtures::{HbaMode, PostgresFixture};
use tablepro_test_support::conformance::test_liveness;
use tokio::time::Instant;
use tokio_util::sync::CancellationToken;

const CALL: Duration = Duration::from_secs(30);

fn within() -> CallOptions {
    CallOptions::new(Some(Instant::now() + CALL), CancellationToken::new())
}

fn statement(sql: &str) -> Statement {
    let mut builder = StatementBuilder::new();
    builder.push_sql(sql);
    builder.finish()
}

async fn connect(fixture: &PostgresFixture) -> Arc<dyn Connection> {
    let liveness = test_liveness();
    let endpoint = NetworkEndpoint::new(fixture.host(), fixture.port()).expect("a valid endpoint");
    let credentials = fixture.password_credentials();
    let options = ConnectOptions {
        target: ConnectTarget::Network(NetworkTarget {
            transport: Arc::new(DirectTcpTransport::new(endpoint, &liveness)),
            credentials: Credentials::Password {
                username: credentials.username.clone(),
                password: SecretString::from(credentials.password.clone()),
            },
            database: Some(fixture.database().to_owned()),
            tls: TlsConfig::disabled(),
        }),
        workspace_settings: WorkspaceSettings::workspace(false),
        liveness,
        environment: ConnectEnvironment::new("test"),
    };
    PgDriver
        .connect(options, CancellationToken::new())
        .await
        .expect("a connection")
}

async fn setup(connection: &dyn Connection, statements: &[&str]) {
    let steps = statements
        .iter()
        .map(|sql| GuardedStatement::unguarded(statement(sql)))
        .collect();
    let batch = WriteBatch::new(
        WriteKind::SchemaChanges,
        TableRef::unqualified("users"),
        steps,
        ForeignKeyMode::Enforced,
    );
    connection
        .write_batch(&batch, within())
        .await
        .expect("the setup statements");
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
#[ignore = "requires docker"]
async fn replace_by_unique_key_saves() {
    let fixture = PostgresFixture::start(HbaMode::Password)
        .await
        .expect("a PostgreSQL container");
    let connection = connect(&fixture).await;
    setup(
        connection.as_ref(),
        &[
            "CREATE TABLE users (id integer PRIMARY KEY, email text NOT NULL UNIQUE)",
            "INSERT INTO users VALUES (1, 'a')",
        ],
    )
    .await;
    let table = TableRef::new(Some("public".to_owned()), "users");
    let columns = connection.fetch_columns(&table, within()).await.expect("the columns");
    let tracker = TabTrackerHandle::default();
    let _ = tracker.apply(TrackerEdit::DeleteRows {
        persisted: vec![(
            RowKey::from_pk_values(&[Value::Int(1)]).expect("a key"),
            vec![Value::Int(1), Value::Text("a".to_owned())].into(),
        )],
        drafts: Vec::new(),
    });
    let _ = tracker.apply(TrackerEdit::InsertDraft {
        cells: vec![Value::Int(2), Value::Text("a".to_owned())]
            .into_iter()
            .map(CellInput::Value)
            .collect(),
    });

    let changes = tracker.change_set(&columns).expect("a change set");
    let plan = plan_save(
        connection.dialect().as_ref(),
        &table,
        &columns,
        &pk_identity(&columns),
        &changes.changes,
    )
    .expect("a save plan");
    connection.write_batch(&plan.batch, within()).await.expect("the save");

    let saved = connection
        .query_bound(
            &statement("SELECT id FROM users WHERE email = 'a'"),
            RowLimit::EDITOR_DEFAULT,
            within(),
        )
        .await
        .expect("a read")
        .rows;
    assert_eq!(saved, vec![vec![Value::Int(2)]]);
}
