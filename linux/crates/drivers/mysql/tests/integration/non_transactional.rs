//! Saves on engines that cannot roll back: each statement lands as it
//! runs, and the error says how many did.

use tablepro_core::statement::GuardedStatement;
use tablepro_core::{DriverError, ForeignKeyMode, StatementOutcome, WriteBatch, WriteKind};
use tablepro_test_fixtures::MysqlFlavour;

use crate::support::{CALL, FLAVOURS, connect, count, setup, start, statement, table, within};

fn guarded(sql: &str, rows: u64) -> GuardedStatement {
    GuardedStatement::affecting_exactly(statement(sql), rows)
}

fn plain(sql: &str) -> GuardedStatement {
    GuardedStatement::unguarded(statement(sql))
}

fn batch(name: &str, steps: Vec<GuardedStatement>) -> WriteBatch {
    WriteBatch::new(WriteKind::RowChanges, table(name), steps, ForeignKeyMode::Enforced)
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
#[ignore = "requires docker"]
async fn myisam_second_statement_fails_partially_applied_applied_1() {
    for flavour in FLAVOURS {
        let fixture = start(flavour).await;
        let connection = connect(&fixture, false).await;
        setup(
            connection.as_ref(),
            &["CREATE TABLE plain (id int PRIMARY KEY) ENGINE=MyISAM"],
        )
        .await;

        let outcome = connection
            .write_batch(
                &batch(
                    "plain",
                    vec![
                        plain("INSERT INTO plain VALUES (1)"),
                        plain("INSERT INTO plain VALUES (1)"),
                    ],
                ),
                within(CALL),
            )
            .await;

        assert!(
            matches!(
                outcome,
                Err(DriverError::PartiallyApplied {
                    applied: 1,
                    statement_index: 1,
                    failed_outcome: StatementOutcome::Failed,
                    ..
                })
            ),
            "{flavour:?}: {outcome:?}"
        );
        assert_eq!(count(connection.as_ref(), "SELECT COUNT(*) FROM plain").await, 1);
        connection.close().await.expect("a close");
    }
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
#[ignore = "requires docker"]
async fn myisam_guard_mismatch_at_second_step_stops_partially_applied() {
    let fixture = start(MysqlFlavour::Mysql).await;
    let connection = connect(&fixture, false).await;
    setup(
        connection.as_ref(),
        &[
            "CREATE TABLE plain (id int PRIMARY KEY, v int) ENGINE=MyISAM",
            "INSERT INTO plain VALUES (1, 0), (2, 0)",
        ],
    )
    .await;

    let outcome = connection
        .write_batch(
            &batch(
                "plain",
                vec![
                    guarded("UPDATE plain SET v = 1 WHERE id = 1", 1),
                    guarded("UPDATE plain SET v = 1 WHERE id = 99", 1),
                    guarded("UPDATE plain SET v = 1 WHERE id = 2", 1),
                ],
            ),
            within(CALL),
        )
        .await;

    let source = match &outcome {
        Err(DriverError::PartiallyApplied {
            applied: 1,
            statement_index: 1,
            source,
            ..
        }) => source.as_ref(),
        other => panic!("{other:?}"),
    };
    assert!(matches!(
        source,
        DriverError::RowGuardFailed {
            statement_index: 1,
            expected: 1,
            actual: 0
        }
    ));
    assert_eq!(
        count(connection.as_ref(), "SELECT COUNT(*) FROM plain WHERE v = 1").await,
        1
    );
    connection.close().await.expect("a close");
}

/// The probe-free guard of the first statement fails before anything
/// else runs, so nothing is applied.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
#[ignore = "requires docker"]
async fn myisam_guard_mismatch_at_first_step_row_guard_failed_nothing_applied() {
    let fixture = start(MysqlFlavour::Mysql).await;
    let connection = connect(&fixture, false).await;
    setup(
        connection.as_ref(),
        &[
            "CREATE TABLE plain (id int PRIMARY KEY, v int) ENGINE=MyISAM",
            "INSERT INTO plain VALUES (1, 0)",
        ],
    )
    .await;

    let outcome = connection
        .write_batch(
            &batch(
                "plain",
                vec![
                    guarded("UPDATE plain SET v = 1 WHERE id = 99", 1),
                    guarded("UPDATE plain SET v = 1 WHERE id = 1", 1),
                ],
            ),
            within(CALL),
        )
        .await;

    assert_eq!(
        outcome,
        Err(DriverError::RowGuardFailed {
            statement_index: 0,
            expected: 1,
            actual: 0
        })
    );
    assert_eq!(
        count(connection.as_ref(), "SELECT COUNT(*) FROM plain WHERE v = 1").await,
        0
    );
    connection.close().await.expect("a close");
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
#[ignore = "requires docker"]
async fn aria_table_uses_statement_by_statement() {
    let fixture = start(MysqlFlavour::Mariadb).await;
    let connection = connect(&fixture, false).await;
    setup(
        connection.as_ref(),
        &["CREATE TABLE aria (id int PRIMARY KEY) ENGINE=Aria"],
    )
    .await;

    let outcome = connection
        .write_batch(
            &batch(
                "aria",
                vec![
                    plain("INSERT INTO aria VALUES (1)"),
                    plain("INSERT INTO aria VALUES (1)"),
                ],
            ),
            within(CALL),
        )
        .await;

    assert!(
        matches!(outcome, Err(DriverError::PartiallyApplied { applied: 1, .. })),
        "{outcome:?}"
    );
    assert_eq!(count(connection.as_ref(), "SELECT COUNT(*) FROM aria").await, 1);
    connection.close().await.expect("a close");
}

/// An InnoDB save rolls back, but what its trigger wrote into a MyISAM
/// table stays, and the server's warning 1196 says so.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
#[ignore = "requires docker"]
async fn innodb_trigger_into_myisam_rollback_warning_1196_partially_applied() {
    for flavour in FLAVOURS {
        let fixture = start(flavour).await;
        let connection = connect(&fixture, false).await;
        setup(
            connection.as_ref(),
            &[
                "CREATE TABLE source (id int PRIMARY KEY) ENGINE=InnoDB",
                "CREATE TABLE audit (id int) ENGINE=MyISAM",
                "CREATE TRIGGER source_audit AFTER INSERT ON source FOR EACH ROW INSERT INTO audit VALUES (NEW.id)",
            ],
        )
        .await;

        let outcome = connection
            .write_batch(
                &batch(
                    "source",
                    vec![
                        plain("INSERT INTO source VALUES (1)"),
                        plain("INSERT INTO source VALUES (1)"),
                    ],
                ),
                within(CALL),
            )
            .await;

        assert!(
            matches!(
                outcome,
                Err(DriverError::PartiallyApplied {
                    applied: 1,
                    statement_index: 1,
                    ..
                })
            ),
            "{flavour:?}: {outcome:?}"
        );
        assert_eq!(count(connection.as_ref(), "SELECT COUNT(*) FROM source").await, 0);
        assert_eq!(count(connection.as_ref(), "SELECT COUNT(*) FROM audit").await, 1);
        connection.close().await.expect("a close");
    }
}
