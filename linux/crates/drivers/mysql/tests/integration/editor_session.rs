//! Where an editor session stands with a transaction, asked of the
//! server: MariaDB's @@in_transaction, MySQL's performance_schema.

use tablepro_core::{CallOptions, EditorSession, TransactionState};
use tablepro_test_fixtures::MysqlFlavour;

use crate::support::{CALL, connect, connect_root, run_ok, session, start, within};

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
