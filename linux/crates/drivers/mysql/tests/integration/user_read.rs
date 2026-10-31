//! A read of user SQL runs one statement, as the server parses it.

use tablepro_core::{Connection, DriverError, ReadStatement, StreamSummary, UserSql};

use crate::support::{CALL, EventSink, Events, FLAVOURS, connect, setup, start, within};

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
