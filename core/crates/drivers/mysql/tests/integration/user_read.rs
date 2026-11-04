//! A read of user SQL runs one statement, as the server parses it.

use tablepro_core::{Connection, DriverError, ReadStatement, StreamSummary, UserSql};

use crate::support::{CALL, EventSink, Events, FLAVOURS, connect, count, setup, start, statement, within};

async fn read(connection: &dyn Connection, sql: &str) -> (Result<StreamSummary, DriverError>, Events) {
    let events = Events::default();
    let outcome = connection
        .stream_read(
            &ReadStatement::User(UserSql::new(sql)),
            Box::new(EventSink::new(&events)),
            within(CALL),
        )
        .await;
    (outcome, events)
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
#[ignore = "requires docker"]
async fn a_read_runs_one_statement_and_takes_any_kind_the_server_parses() {
    for flavour in FLAVOURS {
        let fixture = start(flavour).await;
        let connection = connect(&fixture, false).await;
        setup(
            connection.as_ref(),
            &["CREATE TABLE t (id int)", "INSERT INTO t VALUES (1)"],
        )
        .await;

        let (two, events) = read(connection.as_ref(), "SELECT 1; SELECT 2").await;
        assert!(two.is_err(), "{flavour:?}: {two:?}");
        assert!(events.rows().is_empty(), "{flavour:?}");

        for sql in [
            "SELECT id FROM t",
            "SHOW TABLES",
            "DESCRIBE t",
            "EXPLAIN SELECT * FROM t",
        ] {
            let (outcome, events) = read(connection.as_ref(), sql).await;
            assert!(outcome.is_ok(), "{flavour:?}: {sql}: {outcome:?}");
            assert!(!events.rows().is_empty(), "{flavour:?}: {sql}");
        }
    }
}

/// The server ends the read's read-only transaction before DDL, so the
/// session itself is read-only too. The statement goes below the check
/// of user SQL, as a read the app built.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
#[ignore = "requires docker"]
async fn a_read_on_a_writable_connection_creates_no_table() {
    for flavour in FLAVOURS {
        let fixture = start(flavour).await;
        let connection = connect(&fixture, false).await;
        let events = Events::default();

        let outcome = connection
            .stream_read(
                &ReadStatement::Generated(statement("CREATE TABLE made_by_a_read (a int)")),
                Box::new(EventSink::new(&events)),
                within(CALL),
            )
            .await;

        assert!(outcome.is_err(), "{flavour:?}: {outcome:?}");
        assert_eq!(
            count(
                connection.as_ref(),
                "SELECT COUNT(*) FROM information_schema.TABLES \
                 WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = 'made_by_a_read'"
            )
            .await,
            0,
            "{flavour:?}"
        );
    }
}
