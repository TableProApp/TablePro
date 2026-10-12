//! What the driver promises on both MySQL 8.4 and MariaDB 11.4: the
//! session it sets up, how it stops statements, and how saves fail.

use std::time::Duration;

use tablepro_core::{
    DriverError, ReadOnlyRefusal, RowLimit, RunEnd, RunOptions, TimeoutPhase, Value, WorkspaceSettings, WriteKind,
};
use tablepro_test_fixtures::{MysqlFlavour, MysqlOptions};
use tokio_util::sync::CancellationToken;

use crate::support::{
    CALL, FLAVOURS, apply, connect, connect_root, connect_settings, count, rows, run, run_ok, run_with, scalar,
    session, session_scalar, setup, start, start_with, statement, within,
};

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
#[ignore = "requires docker"]
async fn server_info_product_flavour() {
    for (flavour, product) in [(MysqlFlavour::Mysql, "MySQL"), (MysqlFlavour::Mariadb, "MariaDB")] {
        let fixture = start(flavour).await;
        let connection = connect(&fixture, false).await;

        let info = connection.server_info();
        assert_eq!(info.product, product);
        let expected = match flavour {
            MysqlFlavour::Mysql => (8, 4),
            MysqlFlavour::Mariadb => (11, 4),
        };
        assert_eq!((info.major, info.minor), expected, "{}", info.version);
        connection.close().await.expect("a close");
    }
}

/// sqlx would turn PIPES_AS_CONCAT on and pin the zone; neither may
/// reach a session, so `||` stays OR and the editor keeps the server's
/// zone.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
#[ignore = "requires docker"]
async fn pipes_as_concat_off_time_zone_system() {
    for flavour in FLAVOURS {
        let fixture = start(flavour).await;
        let connection = connect(&fixture, false).await;

        assert_eq!(
            scalar(connection.as_ref(), "SELECT 'a' || 'b'").await,
            Value::Int(0),
            "{flavour:?}"
        );
        let editor = session(connection.as_ref()).await;
        assert_eq!(
            session_scalar(editor.as_ref(), "SELECT @@session.time_zone = @@global.time_zone").await,
            "1",
            "{flavour:?}"
        );
        editor.close().await;
        connection.close().await.expect("a close");
    }
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
#[ignore = "requires docker"]
async fn editor_collation_connection_matches_server_default() {
    for flavour in FLAVOURS {
        let fixture = start(flavour).await;
        let connection = connect(&fixture, false).await;
        let editor = session(connection.as_ref()).await;

        assert_eq!(
            session_scalar(
                editor.as_ref(),
                "SELECT @@collation_connection = COLLATION(_utf8mb4'x')"
            )
            .await,
            "1",
            "{flavour:?}"
        );
        let collation = session_scalar(editor.as_ref(), "SELECT @@collation_connection").await;
        assert_ne!(collation, "utf8mb4_unicode_ci", "{flavour:?}");
        editor.close().await;
        connection.close().await.expect("a close");
    }
}

/// A TIMESTAMP written in one zone reads in the workspace as the instant
/// it is, with a UTC offset.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
#[ignore = "requires docker"]
async fn workspace_timestamp_decodes_utc_offset() {
    for flavour in FLAVOURS {
        let fixture = start(flavour).await;
        let connection = connect(&fixture, false).await;
        setup(
            connection.as_ref(),
            &["CREATE TABLE stamps (id int PRIMARY KEY, at timestamp(3) NULL)"],
        )
        .await;
        let editor = session(connection.as_ref()).await;
        run_ok(
            editor.as_ref(),
            "SET time_zone = '+05:00'; INSERT INTO stamps VALUES (1, '2025-01-01 10:00:00.250')",
        )
        .await;
        editor.close().await;

        let value = scalar(connection.as_ref(), "SELECT at FROM stamps").await;
        let Value::TimestampTz(tablepro_core::value::Temporal::Finite(instant)) = value else {
            panic!("{flavour:?}: the TIMESTAMP read as {value:?}");
        };
        assert_eq!(instant.offset().local_minus_utc(), 0);
        assert_eq!(
            instant.utc().format("%Y-%m-%d %H:%M:%S%.3f").to_string(),
            "2025-01-01 05:00:00.250"
        );
        connection.close().await.expect("a close");
    }
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
#[ignore = "requires docker"]
async fn two_result_set_script_two_started() {
    for flavour in FLAVOURS {
        let fixture = start(flavour).await;
        let connection = connect(&fixture, false).await;
        let editor = session(connection.as_ref()).await;

        let events = run_ok(editor.as_ref(), "SELECT 1; SELECT 2, 3").await;

        assert_eq!(events.started(), 2, "{flavour:?}");
        assert_eq!(events.rows().len(), 2, "{flavour:?}");
        editor.close().await;
        connection.close().await.expect("a close");
    }
}

/// The server parses a routine body itself, so a script that creates
/// one runs as written, with or without the mysql client's DELIMITER.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
#[ignore = "requires docker"]
async fn create_trigger_and_procedure_in_session() {
    for flavour in FLAVOURS {
        let fixture = start(flavour).await;
        // MySQL's binary log is on, so a trigger or routine needs a login
        // trusted to create one.
        let connection = connect_root(&fixture).await;
        let editor = session(connection.as_ref()).await;

        run_ok(
            editor.as_ref(),
            "CREATE TABLE tt (a int); \
             CREATE TRIGGER tt_bump BEFORE INSERT ON tt FOR EACH ROW BEGIN SET NEW.a = NEW.a + 1; END; \
             CREATE PROCEDURE answer() BEGIN SELECT 41 + 1 AS answer; END",
        )
        .await;
        run_ok(
            editor.as_ref(),
            "DELIMITER //\nCREATE PROCEDURE twice() BEGIN SELECT 1; SELECT 2; END//\nDELIMITER ;\nINSERT INTO tt VALUES (1);",
        )
        .await;

        assert_eq!(
            session_scalar(editor.as_ref(), "CALL answer()").await,
            "42",
            "{flavour:?}"
        );
        assert_eq!(
            session_scalar(editor.as_ref(), "SELECT a FROM tt").await,
            "2",
            "{flavour:?}"
        );
        let events = run_ok(editor.as_ref(), "CALL twice()").await;
        assert_eq!(events.started(), 2, "{flavour:?}");
        editor.close().await;
        connection.close().await.expect("a close");
    }
}

/// A cancelled SLEEP leaves the editor's thread idle on the server.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
#[ignore = "requires docker"]
async fn sleep_30_cancelled_thread_idle() {
    for flavour in FLAVOURS {
        let fixture = start(flavour).await;
        let connection = connect(&fixture, false).await;
        let editor = session(connection.as_ref()).await;
        let editor_id = session_scalar(editor.as_ref(), "SELECT CONNECTION_ID()").await;
        let cancel = CancellationToken::new();
        let cancelling = {
            let cancel = cancel.clone();
            async move {
                tokio::time::sleep(Duration::from_millis(500)).await;
                cancel.cancel();
            }
        };

        let ((summary, _), ()) = tokio::join!(
            run_with(editor.as_ref(), "SELECT SLEEP(30)", RunOptions::new(cancel)),
            cancelling
        );

        assert_eq!(summary.end, RunEnd::Cancelled, "{flavour:?}");
        let command = scalar(
            connection.as_ref(),
            &format!("SELECT COMMAND FROM information_schema.PROCESSLIST WHERE ID = {editor_id}"),
        )
        .await;
        assert_eq!(command, Value::Text("Sleep".to_owned()), "{flavour:?}");
        assert_eq!(session_scalar(editor.as_ref(), "SELECT 7").await, "7");
        editor.close().await;
        connection.close().await.expect("a close");
    }
}

/// A read-only connection refuses a save itself, and its editor session
/// is refused by the server with 1792, for a row change and DDL alike.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
#[ignore = "requires docker"]
async fn read_only_insert_and_create_1792() {
    for flavour in FLAVOURS {
        let fixture = start(flavour).await;
        let owner = connect(&fixture, false).await;
        setup(owner.as_ref(), &["CREATE TABLE ro (id int PRIMARY KEY)"]).await;
        let reader = connect(&fixture, true).await;

        let saved = apply(reader.as_ref(), WriteKind::RowChanges, &["INSERT INTO ro VALUES (1)"]).await;
        assert_eq!(saved, Err(DriverError::ReadOnly(ReadOnlyRefusal::ClientGuard)));

        let editor = session(reader.as_ref()).await;
        for sql in ["INSERT INTO ro VALUES (1)", "CREATE TABLE ro_created (id int)"] {
            let (summary, _) = run(editor.as_ref(), sql).await;
            let number = match &summary.end {
                RunEnd::Failed(DriverError::ReadOnly(ReadOnlyRefusal::ServerRejected(diagnostics))) => {
                    diagnostics.code.as_ref().map(ToString::to_string)
                }
                other => panic!("{flavour:?}: `{sql}` ended {other:?}"),
            };
            assert_eq!(number.as_deref(), Some("1792"), "{flavour:?}");
        }
        assert_eq!(count(owner.as_ref(), "SELECT COUNT(*) FROM ro").await, 0);
        editor.close().await;
        reader.close().await.expect("a close");
        owner.close().await.expect("a close");
    }
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
#[ignore = "requires docker"]
async fn statement_timeout_1s_sleep_2_timeout() {
    for flavour in FLAVOURS {
        let fixture = start(flavour).await;
        let settings = WorkspaceSettings {
            statement_timeout: Duration::from_secs(1),
            ..WorkspaceSettings::workspace(false)
        };
        let connection = connect_settings(&fixture, settings).await;

        let outcome = connection
            .query_bound(
                &statement("SELECT 1 FROM DUAL WHERE SLEEP(2) = 0"),
                RowLimit::EDITOR_DEFAULT,
                within(CALL),
            )
            .await;

        assert!(
            matches!(
                outcome,
                Err(DriverError::Timeout {
                    phase: TimeoutPhase::Statement,
                    server_cancelled: true
                })
            ),
            "{flavour:?}: {outcome:?}"
        );
        assert_eq!(scalar(connection.as_ref(), "SELECT 1").await, Value::Int(1));
        connection.close().await.expect("a close");
    }
}

/// MariaDB's statement bound is lifted for a schema change and put back
/// on the same connection afterwards.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
#[ignore = "requires docker"]
async fn mariadb_schema_changes_restores_max_statement_time() {
    let fixture = start(MysqlFlavour::Mariadb).await;
    let settings = WorkspaceSettings {
        statement_timeout: Duration::from_secs(1),
        ..WorkspaceSettings::workspace(false)
    };
    let connection = connect_settings(&fixture, settings).await;

    apply(
        connection.as_ref(),
        WriteKind::SchemaChanges,
        &["CREATE TABLE slow AS SELECT SLEEP(2) AS id"],
    )
    .await
    .expect("the schema change ran past the statement bound");

    let bound = scalar(connection.as_ref(), "SELECT @@SESSION.max_statement_time").await;
    let seconds = tablepro_core::export::value_to_text(&bound).and_then(|text| text.parse::<f64>().ok());
    assert_eq!(seconds, Some(1.0), "{bound:?}");
    connection.close().await.expect("a close");
}

/// A row another session holds makes a save wait out the lock bound and
/// fail as a lock wait, with nothing applied.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
#[ignore = "requires docker"]
async fn lock_wait_timeout_1205() {
    for flavour in FLAVOURS {
        let fixture = start(flavour).await;
        let settings = WorkspaceSettings {
            lock_timeout: Duration::from_secs(1),
            ..WorkspaceSettings::workspace(false)
        };
        let connection = connect_settings(&fixture, settings).await;
        setup(
            connection.as_ref(),
            &[
                "CREATE TABLE locked (id int PRIMARY KEY, v int) ENGINE=InnoDB",
                "INSERT INTO locked VALUES (1, 0)",
            ],
        )
        .await;
        let holder = session(connection.as_ref()).await;
        run_ok(holder.as_ref(), "BEGIN; UPDATE locked SET v = 1 WHERE id = 1").await;

        let outcome = crate::support::apply_on(
            connection.as_ref(),
            WriteKind::RowChanges,
            &crate::support::table("locked"),
            &["UPDATE locked SET v = 2 WHERE id = 1"],
        )
        .await;

        let source = match &outcome {
            Err(DriverError::RolledBack {
                statement_index: 0,
                source,
            }) => source.as_ref(),
            other => panic!("{flavour:?}: {other:?}"),
        };
        assert!(
            matches!(
                source,
                DriverError::Timeout {
                    phase: TimeoutPhase::LockWait,
                    ..
                }
            ),
            "{flavour:?}: {source:?}"
        );
        run_ok(holder.as_ref(), "ROLLBACK").await;
        holder.close().await;
        connection.close().await.expect("a close");
    }
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
#[ignore = "requires docker"]
async fn mysql_expression_index_key() {
    let fixture = start(MysqlFlavour::Mysql).await;
    let connection = connect(&fixture, false).await;
    setup(
        connection.as_ref(),
        &[
            "CREATE TABLE people (id int PRIMARY KEY, name varchar(50))",
            "CREATE INDEX people_lower ON people ((lower(name)) DESC, id)",
        ],
    )
    .await;

    let indexes = connection
        .fetch_indexes(&crate::support::table("people"), within(CALL))
        .await
        .expect("the indexes");

    let index = indexes
        .iter()
        .find(|index| index.name == "people_lower")
        .expect("the expression index");
    assert!(
        matches!(
            &index.keys[0],
            tablepro_core::meta::IndexKey::Expression { sql, descending: true } if sql.contains("lower")
        ),
        "{:?}",
        index.keys
    );
    assert_eq!(index.keys[1].column_name(), Some("id"));
    assert!(indexes.iter().any(|index| index.primary));
    connection.close().await.expect("a close");
}

/// DDL commits as it goes: a failure at the second statement leaves the
/// first applied.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
#[ignore = "requires docker"]
async fn schema_changes_second_statement_fails_partially_applied() {
    for flavour in FLAVOURS {
        let fixture = start(flavour).await;
        let connection = connect(&fixture, false).await;

        let outcome = apply(
            connection.as_ref(),
            WriteKind::SchemaChanges,
            &["CREATE TABLE first_made (id int)", "CREATE TABLE first_made (id int)"],
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
        assert_eq!(count(connection.as_ref(), "SELECT COUNT(*) FROM first_made").await, 0);
        connection.close().await.expect("a close");
    }
}

/// The workspace pins backslashes to be escapes whatever the server's
/// global sql_mode; an editor session keeps the server's mode.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
#[ignore = "requires docker"]
async fn workspace_session_strips_no_backslash_escapes() {
    for flavour in FLAVOURS {
        let options = MysqlOptions::new(flavour)
            .allowing_plaintext()
            .with_server_argument("--sql-mode=NO_BACKSLASH_ESCAPES,STRICT_TRANS_TABLES");
        let fixture = start_with(options).await;
        let connection = connect(&fixture, false).await;

        let mode = scalar(connection.as_ref(), "SELECT @@SESSION.sql_mode").await;
        let mode = crate::support::text(&mode);
        assert!(!mode.contains("NO_BACKSLASH_ESCAPES"), "{flavour:?}: {mode}");
        assert!(mode.contains("STRICT_TRANS_TABLES"), "{flavour:?}: {mode}");
        assert_eq!(
            scalar(connection.as_ref(), r"SELECT LENGTH('a\\b')").await,
            Value::Int(3)
        );

        let editor = session(connection.as_ref()).await;
        assert_eq!(
            session_scalar(editor.as_ref(), r"SELECT LENGTH('a\\b')").await,
            "4",
            "{flavour:?}"
        );
        editor.close().await;
        connection.close().await.expect("a close");
    }
}

/// caching_sha2_password over plaintext TCP falls back to full
/// authentication, which needs sqlx's RSA support.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
#[ignore = "requires docker"]
async fn caching_sha2_without_tls_uses_rsa() {
    let fixture = start(MysqlFlavour::Mysql).await;
    let root = connect_root(&fixture).await;

    let plugin = rows(
        root.as_ref(),
        "SELECT plugin FROM mysql.user WHERE user = 'tablepro' AND host = '%'",
    )
    .await;

    assert_eq!(plugin[0][0], Value::Text("caching_sha2_password".to_owned()));
    let connection = connect(&fixture, false).await;
    assert_eq!(scalar(connection.as_ref(), "SELECT 1").await, Value::Int(1));
    connection.close().await.expect("a close");
    root.close().await.expect("a close");
}
