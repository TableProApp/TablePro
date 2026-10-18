//! Where an editor session stands with a transaction, asked of the
//! server: MariaDB's @@in_transaction, MySQL's performance_schema. And
//! what a run does when its reader goes away.

use tablepro_core::{
    CallOptions, EditorSession, EditorSessionState, RowLimit, RunEnd, RunOptions, TransactionState, UserSql,
};
use tablepro_test_fixtures::MysqlFlavour;
use tokio_util::sync::CancellationToken;

use crate::support::{
    CALL, EventSink, Events, FLAVOURS, connect, connect_root, count, run_ok, session, setup, start, within,
};

/// A hundred thousand rows of a kilobyte each: far more than the socket
/// buffers hold, so the server is still sending the SELECT when the
/// reader leaves. The DELETE behind it must never run.
const WIDE_THEN_DELETE: &str = "WITH d AS (SELECT 0 AS n UNION ALL SELECT 1 UNION ALL SELECT 2 UNION ALL SELECT 3 \
     UNION ALL SELECT 4 UNION ALL SELECT 5 UNION ALL SELECT 6 UNION ALL SELECT 7 UNION ALL SELECT 8 \
     UNION ALL SELECT 9) \
     SELECT REPEAT('x', 1000) AS filler FROM d a, d b, d c, d e, d f; \
     DELETE FROM t";

async fn state_after(session: &dyn EditorSession, sql: &str) -> TransactionState {
    let (summary, _) = crate::support::run(session, sql).await;
    summary.transaction_state
}

fn options() -> CallOptions {
    within(CALL)
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
#[ignore = "requires docker"]
async fn transaction_state_mariadb_in_transaction() {
    let fixture = start(MysqlFlavour::Mariadb).await;
    let connection = connect(&fixture, false).await;
    let editor = session(connection.as_ref()).await;

    assert_eq!(state_after(editor.as_ref(), "SELECT 1").await, TransactionState::Idle);
    assert_eq!(
        state_after(editor.as_ref(), "BEGIN").await,
        TransactionState::InTransaction
    );
    assert_eq!(
        editor.transaction_state(options()).await,
        Ok(TransactionState::InTransaction)
    );
    assert_eq!(state_after(editor.as_ref(), "COMMIT").await, TransactionState::Idle);
    editor.close().await;
    connection.close().await.expect("a close");
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
#[ignore = "requires docker"]
async fn mysql_root_in_transaction() {
    let fixture = start(MysqlFlavour::Mysql).await;
    let connection = connect_root(&fixture).await;
    let editor = session(connection.as_ref()).await;
    run_ok(editor.as_ref(), "CREATE TABLE t (id int PRIMARY KEY)").await;

    assert_eq!(state_after(editor.as_ref(), "SELECT 1").await, TransactionState::Idle);
    assert_eq!(
        state_after(editor.as_ref(), "BEGIN; INSERT INTO t VALUES (1)").await,
        TransactionState::InTransaction
    );
    assert_eq!(
        editor.transaction_state(options()).await,
        Ok(TransactionState::InTransaction)
    );
    assert_eq!(state_after(editor.as_ref(), "ROLLBACK").await, TransactionState::Idle);
    editor.close().await;
    connection.close().await.expect("a close");
}

/// A login that cannot read performance_schema gets Unknown, never a
/// guess, and its runs still complete.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
#[ignore = "requires docker"]
async fn mysql_user_without_ps_select_unknown() {
    let fixture = start(MysqlFlavour::Mysql).await;
    let connection = connect(&fixture, false).await;
    let editor = session(connection.as_ref()).await;

    assert_eq!(state_after(editor.as_ref(), "BEGIN").await, TransactionState::Unknown);
    assert_eq!(editor.transaction_state(options()).await, Ok(TransactionState::Unknown));
    run_ok(editor.as_ref(), "COMMIT").await;
    editor.close().await;
    connection.close().await.expect("a close");
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
#[ignore = "requires docker"]
async fn consumer_gone_kills_the_rest_of_the_batch() {
    for flavour in FLAVOURS {
        let fixture = start(flavour).await;
        let connection = connect(&fixture, false).await;
        setup(
            connection.as_ref(),
            &["CREATE TABLE t (id int PRIMARY KEY)", "INSERT INTO t VALUES (1)"],
        )
        .await;
        let editor = session(connection.as_ref()).await;
        let events = Events::default();
        let options =
            RunOptions::new(CancellationToken::new()).with_row_limit(RowLimit::new(1_000_000).expect("a limit"));

        let summary = editor
            .run(
                UserSql::new(WIDE_THEN_DELETE),
                options,
                Box::new(EventSink::new(&events).gone_after(1)),
            )
            .await
            .expect("the run");

        assert_eq!(summary.end, RunEnd::Cancelled, "{flavour:?}");
        assert_eq!(editor.state(), EditorSessionState::Ready, "{flavour:?}");
        // The next run reads whatever the batch left on the wire first,
        // so by now a DELETE that was still coming has run.
        run_ok(editor.as_ref(), "SELECT 1").await;
        assert_eq!(
            count(connection.as_ref(), "SELECT COUNT(*) FROM t").await,
            1,
            "{flavour:?}"
        );
        editor.close().await;
        connection.close().await.expect("a close");
    }
}
