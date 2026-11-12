//! How many times a statement waits on the server, counted on the wire.

use std::sync::Arc;
use std::time::Duration;

use tablepro_core::{Connection, EditorSession, LivenessPolicy, TlsConfig, WorkspaceSettings};
use tablepro_test_fixtures::PostgresFixture;
use tablepro_test_support::conformance::test_liveness;
use tablepro_test_support::{RoundTripCounter, StreamTally};

use crate::support::{connect_with, direct, options_over, password, rows, run_ok, session, setup, start};

struct Wire {
    counter: Arc<RoundTripCounter>,
    connection: Arc<dyn Connection>,
}

async fn wire(read_only: bool, liveness: LivenessPolicy) -> (PostgresFixture, Wire) {
    let fixture = start().await;
    let counter = Arc::new(RoundTripCounter::new(direct(fixture.host(), fixture.port(), &liveness)));
    let connection = connect_with(options_over(
        counter.clone(),
        password(&fixture.password_credentials()),
        fixture.database(),
        TlsConfig::disabled(),
        WorkspaceSettings::workspace(read_only),
        liveness,
    ))
    .await;
    (fixture, Wire { counter, connection })
}

impl Wire {
    async fn editor(&self) -> (Arc<dyn EditorSession>, StreamTally) {
        let before = self.counter.streams().len();
        let session = session(self.connection.as_ref()).await;
        let streams = self.counter.streams();
        assert_eq!(streams.len(), before + 1, "the session opened one connection");
        let tally = streams.last().cloned().expect("the session's connection");
        (session, tally)
    }

    /// Round trips of one workspace read, over every pooled connection.
    async fn read(&self, sql: &str) -> usize {
        let before = self.counter.round_trips();
        rows(self.connection.as_ref(), sql).await;
        self.counter.round_trips() - before
    }
}

/// Round trips of one script on the session's own connection.
async fn run(session: &dyn EditorSession, tally: &StreamTally, sql: &str) -> usize {
    let before = tally.round_trips();
    run_ok(session, sql).await;
    tally.round_trips() - before
}

const TABLE: &[&str] = &[
    "CREATE TABLE t (id int PRIMARY KEY, name text)",
    "INSERT INTO t SELECT n, 'row ' || n FROM generate_series(1, 50) AS n",
];

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
#[ignore = "requires docker"]
async fn an_editor_select_costs_two_round_trips() {
    let (_fixture, wire) = wire(false, test_liveness()).await;
    setup(wire.connection.as_ref(), TABLE).await;
    let (session, tally) = wire.editor().await;

    let traced = run(session.as_ref(), &tally, "SELECT * FROM t").await;
    let untraced = run(session.as_ref(), &tally, "SELECT count(*) FROM t").await;
    run_ok(session.as_ref(), "BEGIN").await;
    let in_transaction = run(session.as_ref(), &tally, "SELECT * FROM t").await;
    assert_eq!([traced, untraced, in_transaction], [2, 2, 2]);
    run_ok(session.as_ref(), "ROLLBACK").await;
    session.close().await;
    wire.connection.close().await.expect("a close");
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
#[ignore = "requires docker"]
async fn a_read_only_editor_select_costs_two_round_trips() {
    let (_fixture, wire) = wire(true, test_liveness()).await;
    let (session, tally) = wire.editor().await;

    let traced = run(session.as_ref(), &tally, "SELECT * FROM pg_catalog.pg_am").await;
    let untraced = run(session.as_ref(), &tally, "SELECT n FROM generate_series(1, 10) AS n").await;
    assert_eq!([traced, untraced], [2, 2]);
    session.close().await;
    wire.connection.close().await.expect("a close");
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
#[ignore = "requires docker"]
async fn a_workspace_read_on_a_pooled_connection_costs_one_round_trip() {
    let (_fixture, wire) = wire(false, test_liveness()).await;
    setup(wire.connection.as_ref(), TABLE).await;
    wire.read("SELECT * FROM t").await;

    let reads = [
        wire.read("SELECT * FROM t").await,
        wire.read("SELECT * FROM t WHERE id > 10").await,
    ];
    assert_eq!(reads, [1, 1]);
    wire.connection.close().await.expect("a close");
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
#[ignore = "requires docker"]
async fn a_pooled_connection_idle_past_the_keepalive_idle_time_answers_first() {
    // Whole seconds: Linux refuses a keepalive idle time under one.
    let idle = Duration::from_secs(1);
    let liveness = LivenessPolicy {
        tcp_keepalive_idle: idle,
        ..test_liveness()
    };
    let (_fixture, wire) = wire(false, liveness).await;
    setup(wire.connection.as_ref(), TABLE).await;
    wire.read("SELECT * FROM t").await;

    tokio::time::sleep(idle + Duration::from_millis(200)).await;
    assert_eq!(
        wire.read("SELECT * FROM t").await,
        2,
        "the recycle check, then the read"
    );
    wire.connection.close().await.expect("a close");
}
