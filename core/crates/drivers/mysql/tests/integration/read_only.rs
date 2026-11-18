//! A read-only editor session stays read-only: no statement it is sent
//! and no function a read calls makes a later statement writable.

use tablepro_core::{DriverError, ReadOnlyRefusal, RunEnd, Value};

use crate::support::{FLAVOURS, connect, run, run_ok, scalar, session, setup, start, text};

const FUNCTIONS: [&str; 3] = [
    "CREATE TABLE t (id int PRIMARY KEY)",
    "CREATE FUNCTION flip() RETURNS int NOT DETERMINISTIC MODIFIES SQL DATA \
     BEGIN SET SESSION transaction_read_only = 0; RETURN 1; END",
    "CREATE FUNCTION wr() RETURNS int NOT DETERMINISTIC MODIFIES SQL DATA \
     BEGIN INSERT INTO t VALUES (9); RETURN 1; END",
];

fn refused_by_server(end: &RunEnd) -> bool {
    matches!(
        end,
        RunEnd::Failed(DriverError::ReadOnly(ReadOnlyRefusal::ServerRejected(_)))
    )
}

// Measured on MySQL 8.4.13 and MariaDB 11.4.13 with only the session's default read-only: each of these made the
// INSERT after it commit.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
#[ignore = "requires docker"]
async fn no_statement_turns_the_session_read_write() {
    for flavour in FLAVOURS {
        let fixture = start(flavour).await;
        let owner = connect(&fixture, false).await;
        setup(owner.as_ref(), &["CREATE TABLE t (id int PRIMARY KEY)"]).await;
        let reader = connect(&fixture, true).await;
        let editor = session(reader.as_ref()).await;

        for turn in [
            "START TRANSACTION READ WRITE",
            "start transaction with consistent snapshot, read write",
            "SET TRANSACTION READ WRITE",
            "SET SESSION TRANSACTION ISOLATION LEVEL READ COMMITTED, READ WRITE",
            "SET SESSION transaction_read_only = 0",
            "SET @@session.transaction_read_only = DEFAULT",
            "SET @x = 1, `transaction_read_only` = OFF",
            "SET tx_read_only = 0",
            "/*!50000 SET SESSION TRANSACTION READ WRITE */",
        ] {
            let (turned, _) = run(editor.as_ref(), turn).await;
            run(editor.as_ref(), "INSERT INTO t VALUES (1)").await;
            run(editor.as_ref(), "COMMIT").await;

            assert_eq!(
                turned.end,
                RunEnd::Failed(DriverError::ReadOnly(ReadOnlyRefusal::ClientGuard)),
                "{flavour:?}: {turn}"
            );
            assert_eq!(
                scalar(owner.as_ref(), "SELECT count(*) FROM t").await,
                Value::Int(0),
                "{flavour:?}: {turn}"
            );
        }
        editor.close().await;
        reader.close().await.expect("a close");
        owner.close().await.expect("a close");
    }
}

// Measured on MySQL 8.4.13 and MariaDB 11.4.13: under the session's default read-only alone, `SELECT flip()` turned
// it off and the next read's `wr()` wrote. A `SELECT` passes every gate as a read.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
#[ignore = "requires docker"]
async fn a_function_a_read_calls_does_not_turn_the_session_read_write() {
    for flavour in FLAVOURS {
        let fixture = start(flavour).await;
        let owner = connect(&fixture, false).await;
        setup(owner.as_ref(), &FUNCTIONS).await;
        let reader = connect(&fixture, true).await;
        let editor = session(reader.as_ref()).await;

        run_ok(editor.as_ref(), "SELECT flip()").await;
        run_ok(editor.as_ref(), "SELECT * FROM t").await;
        let (later, _) = run(editor.as_ref(), "SELECT wr()").await;
        let (same_run, _) = run(editor.as_ref(), "SELECT flip(); SELECT * FROM t; SELECT wr()").await;
        let (one_text, _) = run(
            editor.as_ref(),
            "DELIMITER //\nSELECT flip(); SELECT wr()//\nDELIMITER ;",
        )
        .await;

        assert!(refused_by_server(&later.end), "{flavour:?}: {:?}", later.end);
        assert!(refused_by_server(&same_run.end), "{flavour:?}: {:?}", same_run.end);
        assert!(refused_by_server(&one_text.end), "{flavour:?}: {:?}", one_text.end);
        assert_eq!(
            scalar(owner.as_ref(), "SELECT count(*) FROM t").await,
            Value::Int(0),
            "{flavour:?}"
        );
        editor.close().await;
        reader.close().await.expect("a close");
        owner.close().await.expect("a close");
    }
}

// ROLLBACK clears MySQL 8.4's warnings (measured), so the read-only transaction a read runs in stays open for the
// SHOW WARNINGS after it.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
#[ignore = "requires docker"]
async fn a_read_only_run_keeps_the_warnings_of_its_read() {
    for flavour in FLAVOURS {
        let fixture = start(flavour).await;
        let reader = connect(&fixture, true).await;
        let editor = session(reader.as_ref()).await;

        let warned = run_ok(editor.as_ref(), "SELECT CAST('x' AS SIGNED); SHOW WARNINGS").await;
        let (summary, _) = run(editor.as_ref(), "SELECT 1").await;

        let codes: Vec<String> = warned.rows().iter().filter_map(|row| row.get(1)).map(text).collect();
        assert!(codes.contains(&"1292".to_owned()), "{flavour:?}: {codes:?}");
        assert_eq!(summary.end, RunEnd::Completed, "{flavour:?}");
        editor.close().await;
        reader.close().await.expect("a close");
    }
}
