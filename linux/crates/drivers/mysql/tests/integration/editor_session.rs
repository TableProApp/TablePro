//! Where an editor session stands with a transaction, asked of the
//! server: MariaDB's @@in_transaction, MySQL's performance_schema. And
//! what a run does when its reader goes away.

use std::time::Duration;

use tablepro_core::{
    CallOptions, EditorSession, EditorSessionState, RowLimit, RunEnd, RunOptions, RunSummary, TransactionState, UserSql,
};
use tablepro_test_fixtures::MysqlFlavour;
use tokio_util::sync::CancellationToken;

use crate::support::{
    CALL, EventSink, Events, FLAVOURS, connect, connect_root, count, rows, run_ok, run_with, session, session_scalar,
    setup, start, text, within,
};

/// A thousand rows, which the server has long finished sending when the
/// reader leaves at the first of them, then a DELETE that must never
/// reach it.
const ROWS_THEN_DELETE: &str = "WITH d AS (SELECT 0 AS n UNION ALL SELECT 1 UNION ALL SELECT 2 UNION ALL SELECT 3 \
     UNION ALL SELECT 4 UNION ALL SELECT 5 UNION ALL SELECT 6 UNION ALL SELECT 7 UNION ALL SELECT 8 \
     UNION ALL SELECT 9) \
     SELECT a.n FROM d a, d b, d c; \
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

async fn until_gone(editor: &dyn EditorSession, options: RunOptions) -> RunSummary {
    let events = Events::default();
    editor
        .run(
            UserSql::new(ROWS_THEN_DELETE),
            options,
            Box::new(EventSink::new(&events).gone_after(1)),
        )
        .await
        .expect("the run")
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
#[ignore = "requires docker"]
async fn consumer_gone_sends_nothing_after_the_running_statement() {
    for flavour in FLAVOURS {
        let fixture = start(flavour).await;
        let connection = connect(&fixture, false).await;
        setup(
            connection.as_ref(),
            &["CREATE TABLE t (id int PRIMARY KEY)", "INSERT INTO t VALUES (1)"],
        )
        .await;
        let editor = session(connection.as_ref()).await;

        let gone = until_gone(editor.as_ref(), RunOptions::new(CancellationToken::new())).await;
        assert_eq!(editor.state(), EditorSessionState::Ready, "{flavour:?}");
        // A killed SLEEP returns 1 with no error, so its statement ends
        // as if nothing had stopped it.
        let stopped = stopped_after(editor.as_ref(), "SELECT SLEEP(30); DELETE FROM t").await;

        assert_eq!(gone.end, RunEnd::Cancelled, "{flavour:?}");
        assert_eq!(stopped, RunEnd::Cancelled, "{flavour:?}");
        assert_eq!(editor.state(), EditorSessionState::Ready, "{flavour:?}");
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

/// Stop `sql` half a second in, as the Stop button does.
async fn stopped_after(editor: &dyn EditorSession, sql: &str) -> RunEnd {
    let cancel = CancellationToken::new();
    let cancelling = {
        let cancel = cancel.clone();
        async move {
            tokio::time::sleep(Duration::from_millis(500)).await;
            cancel.cancel();
        }
    };
    let ((summary, _), ()) = tokio::join!(run_with(editor, sql, RunOptions::new(cancel)), cancelling);
    summary.end
}

/// The login is locked once the session is open, so the KILL's own
/// connection is refused: only the statements left unsent keep the row.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
#[ignore = "requires docker"]
async fn a_stop_whose_kill_is_refused_sends_nothing_after_the_running_statement() {
    for flavour in FLAVOURS {
        let fixture = start(flavour).await;
        let root = connect_root(&fixture).await;
        let admin = session(root.as_ref()).await;
        let connection = connect(&fixture, false).await;
        setup(
            connection.as_ref(),
            &["CREATE TABLE t (id int PRIMARY KEY)", "INSERT INTO t VALUES (1)"],
        )
        .await;
        let gone = session(connection.as_ref()).await;
        let late = session(connection.as_ref()).await;
        run_ok(admin.as_ref(), "ALTER USER 'tablepro'@'%' ACCOUNT LOCK").await;

        let summary = until_gone(gone.as_ref(), RunOptions::new(CancellationToken::new())).await;
        let timed_out = run_with(
            late.as_ref(),
            "SELECT 1 FROM DUAL WHERE SLEEP(3) = 0; DELETE FROM t",
            RunOptions::new(CancellationToken::new()).with_deadline(Some(Duration::from_millis(200))),
        )
        .await
        .0;

        assert_eq!(summary.end, RunEnd::Cancelled, "{flavour:?}");
        assert_eq!(
            timed_out.end,
            RunEnd::TimedOut {
                server_cancelled: false
            },
            "{flavour:?}"
        );
        assert_eq!(count(root.as_ref(), "SELECT COUNT(*) FROM t").await, 1, "{flavour:?}");
        run_ok(admin.as_ref(), "ALTER USER 'tablepro'@'%' ACCOUNT UNLOCK").await;
        for editor in [gone, late, admin] {
            editor.close().await;
        }
        connection.close().await.expect("a close");
        root.close().await.expect("a close");
    }
}

/// The server closes the KILL's own connection between two stops, as its
/// wait_timeout does to an idle one: the second stop still lands.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
#[ignore = "requires docker"]
async fn a_stop_lands_after_the_server_closed_the_kill_connection() {
    for flavour in FLAVOURS {
        let fixture = start(flavour).await;
        let root = connect_root(&fixture).await;
        let admin = session(root.as_ref()).await;
        let connection = connect(&fixture, false).await;
        let editor = session(connection.as_ref()).await;
        let editor_id = session_scalar(editor.as_ref(), "SELECT CONNECTION_ID()").await;
        let sleeping = "SELECT 1 FROM DUAL WHERE SLEEP(30) = 0";
        assert_eq!(stopped_after(editor.as_ref(), sleeping).await, RunEnd::Cancelled);
        let others =
            format!("SELECT ID FROM information_schema.PROCESSLIST WHERE USER = 'tablepro' AND ID <> {editor_id}");
        for row in rows(root.as_ref(), &others).await {
            let id = row.first().map(text).expect("an id");
            run_ok(admin.as_ref(), &format!("KILL CONNECTION {id}")).await;
        }

        let end = stopped_after(editor.as_ref(), sleeping).await;

        assert_eq!(end, RunEnd::Cancelled, "{flavour:?}");
        assert_eq!(editor.state(), EditorSessionState::Ready, "{flavour:?}");
        assert_eq!(session_scalar(editor.as_ref(), "SELECT 7").await, "7", "{flavour:?}");
        for editor in [editor, admin] {
            editor.close().await;
        }
        connection.close().await.expect("a close");
        root.close().await.expect("a close");
    }
}

/// A run's first statement is the row limit's SET, and a server that has
/// stopped answering must not keep the run past its deadline there.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
#[ignore = "requires docker"]
async fn a_deadline_reaches_a_run_still_setting_its_row_limit() {
    let fixture = start(MysqlFlavour::Mysql).await;
    let connection = connect(&fixture, false).await;
    let editor = session(connection.as_ref()).await;
    run_ok(editor.as_ref(), "SELECT 1").await;
    fixture.container().pause().await.expect("a paused server");
    let options = RunOptions::new(CancellationToken::new())
        .with_row_limit(RowLimit::new(5).expect("a limit"))
        .with_deadline(Some(Duration::from_millis(300)));

    let returned = tokio::time::timeout(Duration::from_secs(10), run_with(editor.as_ref(), "SELECT 1", options)).await;
    fixture.container().unpause().await.expect("a running server");

    let (summary, _) = returned.expect("the run returned while the server was paused");
    assert_eq!(
        summary.end,
        RunEnd::TimedOut {
            server_cancelled: false
        }
    );
    assert_eq!(editor.state(), EditorSessionState::Lost);
    editor.close().await;
    connection.close().await.expect("a close");
}
