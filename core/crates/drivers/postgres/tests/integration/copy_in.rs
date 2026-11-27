//! Copy-in on an editor session: the rows of a `COPY ... FROM STDIN`
//! sent as they come, in the session's transaction or in one of the
//! driver's own.

use std::time::Duration;

use bytes::Bytes;
use tablepro_core::{
    Connection, CopyInPiece, CopyInSummary, DriverError, EditorSession, EditorSessionState, ReadOnlyRefusal, RunEnd,
    RunOptions, TransactionState, UserSql,
};
use tokio::sync::mpsc;
use tokio_postgres::SimpleQueryMessage;
use tokio_postgres::config::SslMode;
use tokio_util::sync::CancellationToken;

use crate::support::{CALL, connect, run_ok, scalar, session, setup, start, text, within};

const TABLE: &str = "CREATE TABLE t (a int, b text)";

/// The pieces already queued, then their end.
pub async fn queued(pieces: &[&[u8]]) -> mpsc::Receiver<CopyInPiece> {
    let (sender, rows) = mpsc::channel(pieces.len() + 1);
    for piece in pieces {
        sender
            .send(CopyInPiece::Data(Bytes::copy_from_slice(piece)))
            .await
            .expect("queued");
    }
    sender.send(CopyInPiece::End).await.expect("queued");
    rows
}

async fn copy(session: &dyn EditorSession, statement: &str, pieces: &[&[u8]]) -> CopyInSummary {
    session
        .copy_in(
            UserSql::new(statement),
            queued(pieces).await,
            RunOptions::new(CancellationToken::new()),
        )
        .await
        .expect("the copy")
}

async fn value(connection: &dyn Connection, sql: &str) -> String {
    text(&scalar(connection, sql).await)
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
#[ignore = "requires docker"]
async fn text_rows_cut_anywhere_load_and_commit() {
    let fixture = start().await;
    let connection = connect(&fixture, false).await;
    setup(connection.as_ref(), &[TABLE]).await;
    let session = session(connection.as_ref()).await;

    let summary = copy(
        session.as_ref(),
        "COPY t (a, b) FROM stdin",
        &[b"1\tone\r\n2\tt".as_slice(), b"wo\r\n3\t\\N\r\n".as_slice()],
    )
    .await;

    assert_eq!(summary.end, RunEnd::Completed);
    assert_eq!(summary.rows, 3);
    assert_eq!(summary.transaction_state, TransactionState::Idle);
    assert_eq!(value(connection.as_ref(), "SELECT b FROM t WHERE a = 2").await, "two");
    assert_eq!(
        value(connection.as_ref(), "SELECT count(*) FROM t WHERE b IS NULL").await,
        "1"
    );
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
#[ignore = "requires docker"]
async fn csv_with_a_header_and_a_quoted_line_break_loads() {
    let fixture = start().await;
    let connection = connect(&fixture, false).await;
    setup(connection.as_ref(), &[TABLE]).await;
    let session = session(connection.as_ref()).await;

    let summary = copy(
        session.as_ref(),
        "COPY t (a, b) FROM stdin WITH (FORMAT csv, HEADER true)",
        &[b"a,b\n1,\"x\ny\"\n2,z\n"],
    )
    .await;

    assert_eq!(summary.end, RunEnd::Completed);
    assert_eq!(summary.rows, 2);
    assert_eq!(value(connection.as_ref(), "SELECT b FROM t WHERE a = 1").await, "x\ny");
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
#[ignore = "requires docker"]
async fn a_bad_row_fails_the_copy_and_the_session_goes_on() {
    let fixture = start().await;
    let connection = connect(&fixture, false).await;
    setup(connection.as_ref(), &[TABLE]).await;
    let session = session(connection.as_ref()).await;

    let summary = copy(
        session.as_ref(),
        "COPY t (a, b) FROM stdin",
        &[b"1\tok\nnot a number\tx\n"],
    )
    .await;

    let RunEnd::Failed(DriverError::Server(diagnostics)) = &summary.end else {
        panic!("a bad row ended {:?}", summary.end);
    };
    assert_eq!(diagnostics.sqlstate(), Some("22P02"));
    assert_eq!(summary.transaction_state, TransactionState::Idle);
    assert_eq!(value(connection.as_ref(), "SELECT count(*) FROM t").await, "0");
    run_ok(session.as_ref(), "SELECT 1").await;
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
#[ignore = "requires docker"]
async fn a_copy_in_the_users_transaction_is_kept_by_its_commit() {
    let fixture = start().await;
    let connection = connect(&fixture, false).await;
    setup(connection.as_ref(), &[TABLE]).await;
    let session = session(connection.as_ref()).await;

    run_ok(session.as_ref(), "BEGIN").await;
    let summary = copy(session.as_ref(), "COPY t (a, b) FROM stdin", &[b"1\ta\n2\tb\n"]).await;
    let before_commit = value(connection.as_ref(), "SELECT count(*) FROM t").await;
    run_ok(session.as_ref(), "COMMIT").await;

    assert_eq!(summary.end, RunEnd::Completed);
    assert_eq!(summary.transaction_state, TransactionState::InTransaction);
    assert_eq!(before_commit, "0", "the copy committed on its own");
    assert_eq!(value(connection.as_ref(), "SELECT count(*) FROM t").await, "2");
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
#[ignore = "requires docker"]
async fn a_copy_cancelled_while_it_waits_for_rows_keeps_nothing() {
    let fixture = start().await;
    let connection = connect(&fixture, false).await;
    setup(connection.as_ref(), &[TABLE]).await;
    let session = session(connection.as_ref()).await;
    let (sender, rows) = mpsc::channel(4);
    sender
        .send(CopyInPiece::Data(Bytes::from_static(b"1\tone\n")))
        .await
        .expect("queued");
    let cancel = CancellationToken::new();
    let stop = cancel.clone();

    let copying = session.copy_in(UserSql::new("COPY t (a, b) FROM stdin"), rows, RunOptions::new(cancel));
    let stopping = async move {
        tokio::time::sleep(Duration::from_millis(300)).await;
        stop.cancel();
    };
    let (summary, ()) = tokio::join!(copying, stopping);
    drop(sender);

    assert_eq!(summary.expect("the copy").end, RunEnd::Cancelled);
    assert_eq!(value(connection.as_ref(), "SELECT count(*) FROM t").await, "0");
    assert_eq!(
        session.transaction_state(within(CALL)).await,
        Ok(TransactionState::Idle)
    );
    run_ok(session.as_ref(), "SELECT 1").await;
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
#[ignore = "requires docker"]
async fn a_source_that_gives_up_abandons_the_copy() {
    let fixture = start().await;
    let connection = connect(&fixture, false).await;
    setup(connection.as_ref(), &[TABLE]).await;
    let session = session(connection.as_ref()).await;
    let (sender, rows) = mpsc::channel(4);
    sender
        .send(CopyInPiece::Data(Bytes::from_static(b"1\tone\n")))
        .await
        .expect("queued");
    drop(sender);

    let summary = session
        .copy_in(
            UserSql::new("COPY t (a, b) FROM stdin"),
            rows,
            RunOptions::new(CancellationToken::new()),
        )
        .await
        .expect("the copy");

    assert_eq!(summary.end, RunEnd::Cancelled);
    assert_eq!(value(connection.as_ref(), "SELECT count(*) FROM t").await, "0");
    run_ok(session.as_ref(), "SELECT 1").await;
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
#[ignore = "requires docker"]
async fn a_read_only_session_has_the_server_refuse_a_copy() {
    let fixture = start().await;
    let writer = connect(&fixture, false).await;
    setup(writer.as_ref(), &[TABLE]).await;
    let reader = connect(&fixture, true).await;
    let session = session(reader.as_ref()).await;

    let summary = copy(session.as_ref(), "COPY t (a, b) FROM stdin", &[b"1\tone\n"]).await;

    let RunEnd::Failed(DriverError::ReadOnly(ReadOnlyRefusal::ServerRejected(diagnostics))) = &summary.end else {
        panic!("a read-only copy ended {:?}", summary.end);
    };
    assert_eq!(diagnostics.sqlstate(), Some("25006"));
    assert_eq!(summary.transaction_state, TransactionState::Idle);
    assert_eq!(value(writer.as_ref(), "SELECT count(*) FROM t").await, "0");
    run_ok(session.as_ref(), "SELECT 1").await;
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
#[ignore = "requires docker"]
async fn a_copy_refused_at_its_start_says_why_and_the_session_goes_on() {
    let fixture = start().await;
    let connection = connect(&fixture, false).await;
    let session = session(connection.as_ref()).await;

    let summary = copy(session.as_ref(), "COPY missing FROM stdin", &[b"1\n"]).await;

    let RunEnd::Failed(DriverError::Server(diagnostics)) = &summary.end else {
        panic!("a missing table ended {:?}", summary.end);
    };
    assert_eq!(diagnostics.sqlstate(), Some("42P01"));
    assert_eq!(summary.transaction_state, TransactionState::Idle);
    assert_eq!(session.state(), EditorSessionState::Ready);
    let events = run_ok(session.as_ref(), "SELECT 41 + 1").await;
    assert_eq!(text(&events.rows()[0][0]), "42");
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
#[ignore = "requires docker"]
async fn a_copy_refused_in_the_users_transaction_fails_it_until_rollback() {
    let fixture = start().await;
    let connection = connect(&fixture, false).await;
    let session = session(connection.as_ref()).await;

    run_ok(session.as_ref(), "BEGIN").await;
    let summary = copy(session.as_ref(), "COPY missing FROM stdin", &[b"1\n"]).await;
    run_ok(session.as_ref(), "ROLLBACK").await;

    assert!(
        matches!(summary.end, RunEnd::Failed(DriverError::Server(_))),
        "{:?}",
        summary.end
    );
    assert_eq!(summary.transaction_state, TransactionState::Failed);
    assert_eq!(
        session.transaction_state(within(CALL)).await,
        Ok(TransactionState::Idle)
    );
    run_ok(session.as_ref(), "SELECT 1").await;
}

/// The COPY waits on the lock at its Execute, so the cancel request
/// refuses it before copy-in mode.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
#[ignore = "requires docker"]
async fn a_copy_stopped_while_it_waits_on_a_lock_is_cancelled_and_the_session_goes_on() {
    let fixture = start().await;
    let connection = connect(&fixture, false).await;
    setup(connection.as_ref(), &[TABLE]).await;
    let locker = session(connection.as_ref()).await;
    run_ok(locker.as_ref(), "BEGIN").await;
    run_ok(locker.as_ref(), "LOCK TABLE t").await;
    let session = session(connection.as_ref()).await;
    let cancel = CancellationToken::new();
    let stop = cancel.clone();

    let copying = session.copy_in(
        UserSql::new("COPY t (a, b) FROM stdin"),
        queued(&[b"1\tone\n"]).await,
        RunOptions::new(cancel),
    );
    let stopping = async move {
        tokio::time::sleep(Duration::from_millis(300)).await;
        stop.cancel();
    };
    let (summary, ()) = tokio::join!(copying, stopping);
    run_ok(locker.as_ref(), "COMMIT").await;

    assert_eq!(summary.expect("the copy").end, RunEnd::Cancelled);
    assert_eq!(session.state(), EditorSessionState::Ready);
    assert_eq!(
        session.transaction_state(within(CALL)).await,
        Ok(TransactionState::Idle)
    );
    assert_eq!(value(connection.as_ref(), "SELECT count(*) FROM t").await, "0");
    run_ok(session.as_ref(), "SELECT 1").await;
}

/// tokio-postgres 0.7.18 sent a Sync with the COPY's Execute and another
/// with its CopyFail, so a COPY refused before copy-in mode got two
/// ReadyForQuery and the next request read the second. The driver relies
/// on the fork's fix, rust-postgres/rust-postgres#1402.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
#[ignore = "requires docker"]
async fn tokio_postgres_answers_the_request_after_a_copy_refused_at_its_start() {
    let fixture = start().await;
    let credentials = fixture.password_credentials();
    let mut config = tokio_postgres::Config::new();
    config
        .host(fixture.host())
        .port(fixture.port())
        .user(&credentials.username)
        .password(&credentials.password)
        .dbname(fixture.database())
        .ssl_mode(SslMode::Disable);
    let (client, connection) = config.connect(tokio_postgres::NoTls).await.expect("a client");
    let driving = tokio::spawn(connection);

    let refused = client.copy_in::<_, Bytes>("COPY missing FROM STDIN").await;
    let next = tokio::time::timeout(CALL, client.simple_query("SELECT 1"))
        .await
        .expect("an answer in time")
        .expect("the request's own answer");
    drop(client);
    let _ = driving.await;

    assert!(refused.is_err(), "a COPY into a missing table started");
    let row = next.iter().find_map(|message| match message {
        SimpleQueryMessage::Row(row) => Some(row.get(0)),
        _ => None,
    });
    assert_eq!(row, Some(Some("1")));
}
