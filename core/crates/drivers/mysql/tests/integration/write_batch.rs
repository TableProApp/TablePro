//! A save sends each statement on its own, so a stray `;` in one can
//! never run a second statement behind it.

use tablepro_core::WriteKind;

use crate::support::{FLAVOURS, apply, connect, count, setup, start};

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
#[ignore = "requires docker"]
async fn a_statement_after_a_semicolon_never_runs() {
    for flavour in FLAVOURS {
        let fixture = start(flavour).await;
        let connection = connect(&fixture, false).await;
        setup(
            connection.as_ref(),
            &["CREATE TABLE t (id int PRIMARY KEY)", "INSERT INTO t VALUES (1)"],
        )
        .await;

        let smuggled = [
            (WriteKind::RowChanges, "INSERT INTO t VALUES (2); DELETE FROM t"),
            (WriteKind::SchemaChanges, "CREATE TABLE u (id int); DROP TABLE t"),
            // MySQL cannot prepare CREATE TRIGGER, but this text is two
            // statements, so it never reaches the text protocol.
            (
                WriteKind::SchemaChanges,
                "CREATE TRIGGER t_same BEFORE INSERT ON t FOR EACH ROW SET NEW.id = NEW.id; DROP TABLE t",
            ),
        ];
        for (kind, sql) in smuggled {
            let outcome = apply(connection.as_ref(), kind, &[sql]).await;
            assert!(outcome.is_err(), "{flavour:?} `{sql}`: {outcome:?}");
        }
        apply(
            connection.as_ref(),
            WriteKind::SchemaChanges,
            &["CREATE TRIGGER t_same BEFORE INSERT ON t FOR EACH ROW SET NEW.id = NEW.id"],
        )
        .await
        .expect("one trigger, sent as one statement");

        assert_eq!(
            count(connection.as_ref(), "SELECT COUNT(*) FROM t").await,
            1,
            "{flavour:?}"
        );
        connection.close().await.expect("a close");
    }
}
