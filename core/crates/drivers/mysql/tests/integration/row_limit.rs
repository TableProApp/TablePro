//! The editor's row limit: `sql_select_limit` stops a plain SELECT one
//! row past it, and whatever the server sends beyond that is counted,
//! not kept.

use std::sync::Arc;

use tablepro_core::{Connection, EditorSession, RowLimit, RunEnd, RunOptions, Truncation};
use tablepro_test_fixtures::{MysqlFixture, MysqlOptions};
use tokio_util::sync::CancellationToken;

use crate::support::{FLAVOURS, connect, connect_root, count, run_ok, run_with, session, setup, start, start_with};

const BIG_ROWS: u64 = 200_000;

/// Two hundred thousand ids, built from a cross join of digits so no
/// recursion limit is in the way.
const FILL_BIG: &str = "INSERT INTO big (id) \
     SELECT n FROM (SELECT a.d + 10 * b.d + 100 * c.d + 1000 * e.d + 10000 * f.d + 100000 * g.d + 1 AS n \
     FROM (SELECT 0 AS d UNION ALL SELECT 1 UNION ALL SELECT 2 UNION ALL SELECT 3 UNION ALL SELECT 4 \
           UNION ALL SELECT 5 UNION ALL SELECT 6 UNION ALL SELECT 7 UNION ALL SELECT 8 UNION ALL SELECT 9) a \
     CROSS JOIN (SELECT 0 AS d UNION ALL SELECT 1 UNION ALL SELECT 2 UNION ALL SELECT 3 UNION ALL SELECT 4 \
           UNION ALL SELECT 5 UNION ALL SELECT 6 UNION ALL SELECT 7 UNION ALL SELECT 8 UNION ALL SELECT 9) b \
     CROSS JOIN (SELECT 0 AS d UNION ALL SELECT 1 UNION ALL SELECT 2 UNION ALL SELECT 3 UNION ALL SELECT 4 \
           UNION ALL SELECT 5 UNION ALL SELECT 6 UNION ALL SELECT 7 UNION ALL SELECT 8 UNION ALL SELECT 9) c \
     CROSS JOIN (SELECT 0 AS d UNION ALL SELECT 1 UNION ALL SELECT 2 UNION ALL SELECT 3 UNION ALL SELECT 4 \
           UNION ALL SELECT 5 UNION ALL SELECT 6 UNION ALL SELECT 7 UNION ALL SELECT 8 UNION ALL SELECT 9) e \
     CROSS JOIN (SELECT 0 AS d UNION ALL SELECT 1 UNION ALL SELECT 2 UNION ALL SELECT 3 UNION ALL SELECT 4 \
           UNION ALL SELECT 5 UNION ALL SELECT 6 UNION ALL SELECT 7 UNION ALL SELECT 8 UNION ALL SELECT 9) f \
     CROSS JOIN (SELECT 0 AS d UNION ALL SELECT 1) g) digits WHERE n <= 200000";

async fn with_big(fixture: &MysqlFixture) -> (Arc<dyn Connection>, Arc<dyn EditorSession>) {
    let connection = connect(fixture, false).await;
    setup(
        connection.as_ref(),
        &["CREATE TABLE big (id int PRIMARY KEY)", FILL_BIG],
    )
    .await;
    assert_eq!(count(connection.as_ref(), "SELECT COUNT(*) FROM big").await, BIG_ROWS);
    let editor = session(connection.as_ref()).await;
    (connection, editor)
}

fn limited(rows: u64) -> RunOptions {
    RunOptions::new(CancellationToken::new()).with_row_limit(RowLimit::new(rows).expect("a limit"))
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
#[ignore = "requires docker"]
async fn limit_100_over_200k_rows_server_stopped_101_sent() {
    for flavour in FLAVOURS {
        let fixture = start(flavour).await;
        let (connection, editor) = with_big(&fixture).await;

        let (summary, events) = run_with(editor.as_ref(), "SELECT id FROM big", limited(100)).await;

        assert_eq!(summary.end, RunEnd::Completed, "{flavour:?}");
        assert_eq!(events.rows().len(), 100, "{flavour:?}");
        assert_eq!(
            events.finished(),
            [(100, None, Truncation::ServerStopped)],
            "{flavour:?}"
        );
        editor.close().await;
        connection.close().await.expect("a close");
    }
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
#[ignore = "requires docker"]
async fn explicit_limit_150000_read_past_limit() {
    for flavour in FLAVOURS {
        let fixture = start(flavour).await;
        let (connection, editor) = with_big(&fixture).await;

        let (summary, events) = run_with(editor.as_ref(), "SELECT id FROM big LIMIT 150000", limited(100)).await;

        assert_eq!(summary.end, RunEnd::Completed, "{flavour:?}");
        assert_eq!(events.rows().len(), 100, "{flavour:?}");
        assert_eq!(
            events.finished(),
            [(100, Some(150_000), Truncation::ReadPastLimit)],
            "{flavour:?}"
        );
        editor.close().await;
        connection.close().await.expect("a close");
    }
}

/// The limit applies to what the client is sent, never to a subquery.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
#[ignore = "requires docker"]
async fn subquery_count_full() {
    for flavour in FLAVOURS {
        let fixture = start(flavour).await;
        let (connection, editor) = with_big(&fixture).await;

        let (_, events) = run_with(
            editor.as_ref(),
            "SELECT COUNT(*) FROM (SELECT id FROM big) AS every_row",
            limited(100),
        )
        .await;

        assert_eq!(
            events
                .rows()
                .first()
                .and_then(|row| row.first())
                .map(crate::support::text),
            Some(BIG_ROWS.to_string()),
            "{flavour:?}"
        );
        editor.close().await;
        connection.close().await.expect("a close");
    }
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
#[ignore = "requires docker"]
async fn insert_select_copies_200000() {
    for flavour in FLAVOURS {
        let fixture = start(flavour).await;
        let (connection, editor) = with_big(&fixture).await;

        let (summary, events) = run_with(
            editor.as_ref(),
            "CREATE TABLE copied LIKE big; INSERT INTO copied SELECT id FROM big",
            limited(100),
        )
        .await;

        assert_eq!(summary.end, RunEnd::Completed, "{flavour:?}");
        assert_eq!(events.affected().last(), Some(&Some(BIG_ROWS)), "{flavour:?}");
        assert_eq!(
            count(connection.as_ref(), "SELECT COUNT(*) FROM copied").await,
            BIG_ROWS
        );
        editor.close().await;
        connection.close().await.expect("a close");
    }
}

// The server cuts INTO OUTFILE at sql_select_limit too, and a plain read before it leaves the limit set.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
#[ignore = "requires docker"]
async fn select_into_outfile_after_a_limited_read_writes_every_row() {
    for flavour in FLAVOURS {
        let fixture = start_with(
            MysqlOptions::new(flavour)
                .allowing_plaintext()
                .trusting_function_creators()
                .with_server_argument("--secure-file-priv=/tmp"),
        )
        .await;
        let (connection, owner) = with_big(&fixture).await;
        owner.close().await;
        // FILE is a global privilege, which only root holds here.
        let root = connect_root(&fixture).await;
        let editor = session(root.as_ref()).await;

        let (_, before) = run_with(editor.as_ref(), "SELECT id FROM big", limited(100)).await;
        let (summary, written) = run_with(
            editor.as_ref(),
            "SELECT id FROM big INTO OUTFILE '/tmp/every_id.csv'",
            limited(100),
        )
        .await;

        assert_eq!(
            before.finished(),
            [(100, None, Truncation::ServerStopped)],
            "{flavour:?}"
        );
        assert_eq!(summary.end, RunEnd::Completed, "{flavour:?}");
        assert_eq!(written.started(), 0, "{flavour:?}");
        assert_eq!(written.affected(), [Some(BIG_ROWS)], "{flavour:?}");

        // The backslash makes the driver send this whole, so its first word is an INSERT.
        setup(root.as_ref(), &["CREATE TABLE log (path varchar(20))"]).await;
        run_with(editor.as_ref(), "SELECT id FROM big", limited(100)).await;
        let (summary, batch) = run_with(
            editor.as_ref(),
            r"INSERT INTO log VALUES ('C:\\tmp'); SELECT id FROM big INTO OUTFILE '/tmp/whole_batch.csv'",
            limited(100),
        )
        .await;

        assert_eq!(summary.end, RunEnd::Completed, "{flavour:?}");
        assert_eq!(batch.affected(), [Some(1), Some(BIG_ROWS)], "{flavour:?}");
        editor.close().await;
        root.close().await.expect("a close");
        connection.close().await.expect("a close");
    }
}

// A locking read that stopped at the limit would lock only the rows before it.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
#[ignore = "requires docker"]
async fn locking_reads_read_past_limit() {
    for flavour in FLAVOURS {
        let fixture = start(flavour).await;
        let (connection, editor) = with_big(&fixture).await;

        for sql in ["SELECT id FROM big FOR UPDATE", "SELECT id FROM big LOCK IN SHARE MODE"] {
            let (summary, events) = run_with(editor.as_ref(), sql, limited(100)).await;

            assert_eq!(summary.end, RunEnd::Completed, "{flavour:?}: {sql}");
            assert_eq!(events.rows().len(), 100, "{flavour:?}: {sql}");
            assert_eq!(
                events.finished(),
                [(100, Some(BIG_ROWS), Truncation::ReadPastLimit)],
                "{flavour:?}: {sql}"
            );
        }
        editor.close().await;
        connection.close().await.expect("a close");
    }
}

// The limit is set before a run's first statement, so a SET of the user's in the run holds after it.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
#[ignore = "requires docker"]
async fn a_users_own_select_limit_holds_for_the_rest_of_its_run() {
    for flavour in FLAVOURS {
        let fixture = start(flavour).await;
        let (connection, editor) = with_big(&fixture).await;

        let (summary, events) = run_with(
            editor.as_ref(),
            "SET SESSION sql_select_limit = 2; SELECT id FROM big",
            limited(100),
        )
        .await;

        assert_eq!(summary.end, RunEnd::Completed, "{flavour:?}");
        assert_eq!(events.finished(), [(2, Some(2), Truncation::Complete)], "{flavour:?}");
        editor.close().await;
        connection.close().await.expect("a close");
    }
}

/// A SELECT inside a routine is not cut by `sql_select_limit`, so the
/// editor reads it to its end and keeps the limit's worth.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
#[ignore = "requires docker"]
async fn call_procedure_read_past_limit() {
    for flavour in FLAVOURS {
        let fixture = start(flavour).await;
        let (connection, editor) = with_big(&fixture).await;
        run_ok(editor.as_ref(), "CREATE PROCEDURE every_id() SELECT id FROM big").await;

        let (summary, events) = run_with(editor.as_ref(), "CALL every_id()", limited(100)).await;

        assert_eq!(summary.end, RunEnd::Completed, "{flavour:?}");
        assert_eq!(
            events.finished(),
            [(100, Some(BIG_ROWS), Truncation::ReadPastLimit)],
            "{flavour:?}"
        );
        editor.close().await;
        connection.close().await.expect("a close");
    }
}

/// A limited read inside a transaction leaves the transaction open, and
/// the COMMIT after it lands what came before.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
#[ignore = "requires docker"]
async fn begin_insert_big_select_commit_persists() {
    for flavour in FLAVOURS {
        let fixture = start(flavour).await;
        let (connection, editor) = with_big(&fixture).await;
        setup(connection.as_ref(), &["CREATE TABLE kept (id int PRIMARY KEY)"]).await;

        run_ok(editor.as_ref(), "BEGIN; INSERT INTO kept VALUES (1)").await;
        let (summary, _) = run_with(editor.as_ref(), "SELECT id FROM big", limited(100)).await;
        assert_eq!(summary.end, RunEnd::Completed, "{flavour:?}");
        run_ok(editor.as_ref(), "COMMIT").await;

        assert_eq!(
            count(connection.as_ref(), "SELECT COUNT(*) FROM kept").await,
            1,
            "{flavour:?}"
        );
        editor.close().await;
        connection.close().await.expect("a close");
    }
}
