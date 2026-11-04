//! An editor tab's session: its own keyspace, a script split the way
//! cqlsh splits one, the row limit and the read-only guard.

use tablepro_core::{
    DriverError, ReadOnlyRefusal, ResultEvent, ResultSink, RowLimit, RunEnd, RunOptions, SinkFlow, Truncation, UserSql,
    Value,
};
use tokio_util::sync::CancellationToken;

use crate::support::{
    CassandraServer, ScyllaServer, Server, connect, count, load_series, run, run_ok, run_with, session, setup, start,
};

async fn use_moves_only_its_own_session<S: Server>() {
    let fixture = start::<S>().await;
    let connection = connect(&fixture, false).await;
    fixture
        .cql(
            "CREATE KEYSPACE tp_other WITH replication = {'class': 'SimpleStrategy', 'replication_factor': 1};\n\
             CREATE TABLE tp_other.only_here (id int PRIMARY KEY);\n\
             INSERT INTO tp_other.only_here (id) VALUES (1);",
        )
        .await
        .expect("a second keyspace");
    let moved = session(connection.as_ref()).await;
    let other = session(connection.as_ref()).await;

    run_ok(moved.as_ref(), "USE tp_other").await;
    let read = run_ok(moved.as_ref(), "SELECT id FROM only_here").await;
    let (unmoved, _) = run(other.as_ref(), "SELECT id FROM only_here").await;

    assert_eq!(read.rows(), [[Value::Int(1)]]);
    assert!(matches!(unmoved.end, RunEnd::Failed(_)), "{unmoved:?}");
    assert_eq!(
        count(connection.as_ref(), "SELECT COUNT(*) FROM tp_other.only_here").await,
        1
    );
}

async fn a_batch_runs_whole_and_the_next_statement_after_it<S: Server>() {
    let fixture = start::<S>().await;
    let connection = connect(&fixture, false).await;
    setup(
        connection.as_ref(),
        &["CREATE TABLE tablepro.pairs (id int PRIMARY KEY, label text)"],
    )
    .await;
    let session = session(connection.as_ref()).await;

    let events = run_ok(
        session.as_ref(),
        "BEGIN BATCH\n\
         INSERT INTO tablepro.pairs (id, label) VALUES (1, 'a;b');\n\
         INSERT INTO tablepro.pairs (id, label) VALUES (2, 'c');\n\
         APPLY BATCH;\n\
         SELECT COUNT(*) FROM tablepro.pairs;",
    )
    .await;

    let completed = events
        .all()
        .iter()
        .filter(|event| matches!(event, ResultEvent::CommandCompleted { .. }))
        .count();
    assert_eq!(completed, 1, "{:?}", events.all());
    assert_eq!(events.rows(), [[Value::Int(2)]]);
}

async fn the_row_limit_stops_reading_pages<S: Server>() {
    let fixture = start::<S>().await;
    load_series(&fixture, "limited", 20_000).await;
    let connection = connect(&fixture, false).await;
    let session = session(connection.as_ref()).await;
    let limit = RowLimit::new(1_000).expect("a limit");

    let (summary, events) = run_with(
        session.as_ref(),
        "SELECT n FROM tablepro.limited",
        RunOptions::new(CancellationToken::new()).with_row_limit(limit),
    )
    .await;

    assert_eq!(summary.end, RunEnd::Completed);
    assert_eq!(events.rows().len(), 1_000);
    assert!(
        matches!(
            events.finished().as_slice(),
            [ResultEvent::ResultSetFinished {
                retained: 1_000,
                truncation: Truncation::ServerStopped,
                ..
            }]
        ),
        "{:?}",
        events.finished()
    );
}

/// Leaves after the first statement that returns no rows.
struct LeavesAfterACommand;

#[async_trait::async_trait]
impl ResultSink for LeavesAfterACommand {
    async fn accept(&mut self, event: ResultEvent) -> SinkFlow {
        match event {
            ResultEvent::CommandCompleted { .. } => SinkFlow::ConsumerGone,
            _ => SinkFlow::Continue,
        }
    }
}

async fn a_sink_that_leaves_ends_the_script<S: Server>() {
    let fixture = start::<S>().await;
    let connection = connect(&fixture, false).await;
    setup(
        connection.as_ref(),
        &["CREATE TABLE tablepro.steps (id int PRIMARY KEY)"],
    )
    .await;
    let session = session(connection.as_ref()).await;

    let summary = session
        .run(
            UserSql::new("INSERT INTO tablepro.steps (id) VALUES (1);\nINSERT INTO tablepro.steps (id) VALUES (2);"),
            RunOptions::new(CancellationToken::new()),
            Box::new(LeavesAfterACommand),
        )
        .await
        .expect("the run");

    assert_eq!(summary.end, RunEnd::Cancelled);
    assert_eq!(
        count(connection.as_ref(), "SELECT COUNT(*) FROM tablepro.steps").await,
        1
    );
}

async fn a_read_only_session_refuses_a_write_before_sending_it<S: Server>() {
    let fixture = start::<S>().await;
    let writable = connect(&fixture, false).await;
    setup(
        writable.as_ref(),
        &["CREATE TABLE tablepro.guarded (id int PRIMARY KEY)"],
    )
    .await;
    let connection = connect(&fixture, true).await;
    let session = session(connection.as_ref()).await;

    let (refused, _) = run(session.as_ref(), "INSERT INTO tablepro.guarded (id) VALUES (1)").await;
    let read = run_ok(session.as_ref(), "SELECT COUNT(*) FROM tablepro.guarded").await;

    assert_eq!(
        refused.end,
        RunEnd::Failed(DriverError::ReadOnly(ReadOnlyRefusal::ClientGuard))
    );
    assert_eq!(read.rows(), [[Value::Int(0)]]);
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
#[ignore = "requires docker"]
async fn cassandra_use_moves_only_its_own_session() {
    use_moves_only_its_own_session::<CassandraServer>().await;
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
#[ignore = "requires docker"]
async fn scylla_use_moves_only_its_own_session() {
    use_moves_only_its_own_session::<ScyllaServer>().await;
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
#[ignore = "requires docker"]
async fn cassandra_batch_runs_whole() {
    a_batch_runs_whole_and_the_next_statement_after_it::<CassandraServer>().await;
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
#[ignore = "requires docker"]
async fn scylla_batch_runs_whole() {
    a_batch_runs_whole_and_the_next_statement_after_it::<ScyllaServer>().await;
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
#[ignore = "requires docker"]
async fn cassandra_row_limit_stops_reading_pages() {
    the_row_limit_stops_reading_pages::<CassandraServer>().await;
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
#[ignore = "requires docker"]
async fn scylla_row_limit_stops_reading_pages() {
    the_row_limit_stops_reading_pages::<ScyllaServer>().await;
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
#[ignore = "requires docker"]
async fn cassandra_sink_that_leaves_ends_the_script() {
    a_sink_that_leaves_ends_the_script::<CassandraServer>().await;
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
#[ignore = "requires docker"]
async fn scylla_sink_that_leaves_ends_the_script() {
    a_sink_that_leaves_ends_the_script::<ScyllaServer>().await;
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
#[ignore = "requires docker"]
async fn cassandra_read_only_session_refuses_writes() {
    a_read_only_session_refuses_a_write_before_sending_it::<CassandraServer>().await;
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
#[ignore = "requires docker"]
async fn scylla_read_only_session_refuses_writes() {
    a_read_only_session_refuses_a_write_before_sending_it::<ScyllaServer>().await;
}
