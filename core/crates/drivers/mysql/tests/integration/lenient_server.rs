//! A server started with an empty sql_mode stores what it can of a bad
//! value and only warns. The workspace session is strict, so a save or a
//! schema change on such a server fails instead of changing the value.

use tablepro_core::{Value, WriteKind};
use tablepro_test_fixtures::MysqlOptions;

use crate::support::{FLAVOURS, apply_on, connect, rows, session, session_scalar, setup, start_with, table};

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
#[ignore = "requires docker"]
async fn a_value_the_column_cannot_hold_is_refused_not_altered() {
    for flavour in FLAVOURS {
        let fixture = start_with(
            MysqlOptions::new(flavour)
                .allowing_plaintext()
                .with_server_argument("--sql-mode="),
        )
        .await;
        let connection = connect(&fixture, false).await;
        setup(
            connection.as_ref(),
            &[
                "CREATE TABLE lenient (id int PRIMARY KEY, label varchar(5) NOT NULL, \
                 state enum('draft','done') NOT NULL, flag tinyint(1) NOT NULL, note int NULL) ENGINE=InnoDB",
                "INSERT INTO lenient VALUES (1, 'ok', 'draft', 1, NULL)",
                "CREATE TABLE lenient_myisam (id int PRIMARY KEY, label varchar(5) NOT NULL) ENGINE=MyISAM",
            ],
        )
        .await;

        let bad_rows = [
            "UPDATE lenient SET label = 'abcdefgh' WHERE id = 1",
            "UPDATE lenient SET state = 'unknown' WHERE id = 1",
            "UPDATE lenient SET flag = 300 WHERE id = 1",
            "INSERT INTO lenient VALUES (2, 'abcdefgh', 'draft', 0, NULL)",
        ];
        for sql in bad_rows {
            let outcome = apply_on(connection.as_ref(), WriteKind::RowChanges, &table("lenient"), &[sql]).await;
            assert!(outcome.is_err(), "{flavour:?} `{sql}` stored: {outcome:?}");
        }
        let myisam = apply_on(
            connection.as_ref(),
            WriteKind::RowChanges,
            &table("lenient_myisam"),
            &["INSERT INTO lenient_myisam VALUES (1, 'abcdefgh')"],
        )
        .await;
        assert!(myisam.is_err(), "{flavour:?} MyISAM stored a cut value: {myisam:?}");
        let not_null = apply_on(
            connection.as_ref(),
            WriteKind::SchemaChanges,
            &table("lenient"),
            &["ALTER TABLE lenient MODIFY note int NOT NULL"],
        )
        .await;
        assert!(not_null.is_err(), "{flavour:?} a NULL became 0: {not_null:?}");

        assert_eq!(
            rows(connection.as_ref(), "SELECT label, state, flag, note FROM lenient").await,
            [vec![
                Value::Text("ok".to_owned()),
                Value::Text("draft".to_owned()),
                Value::Int(1),
                Value::Null,
            ]],
            "{flavour:?}"
        );
        assert_eq!(
            rows(connection.as_ref(), "SELECT COUNT(*) FROM lenient_myisam").await,
            [vec![Value::Int(0)]],
            "{flavour:?}"
        );

        let editor = session(connection.as_ref()).await;
        let editor_mode = session_scalar(editor.as_ref(), "SELECT @@SESSION.sql_mode").await;
        assert!(
            !editor_mode.contains("STRICT"),
            "{flavour:?}: the editor took the workspace's mode: {editor_mode}"
        );
        editor.close().await;
        connection.close().await.expect("a close");
    }
}
