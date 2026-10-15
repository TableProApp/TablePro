#![allow(clippy::unwrap_used, clippy::expect_used, clippy::panic)]

use crate::{connect, start_pg};
use tablepro_core::{DriverError, OperationControl, Value};

#[tokio::test]
#[ignore = "requires docker"]
async fn select_star_sees_a_column_added_after_the_statement_was_first_prepared() {
    let (_c, opts) = start_pg().await;
    let conn = connect(opts).await;
    conn.execute("CREATE TABLE sp (id int PRIMARY KEY, a int)")
        .await
        .unwrap();
    for _ in 0..8 {
        assert_eq!(conn.query("SELECT * FROM sp").await.unwrap().columns.len(), 2);
    }
    conn.execute("ALTER TABLE sp ADD COLUMN b int").await.unwrap();
    for attempt in 0..8 {
        let result = conn.query("SELECT * FROM sp").await;
        let columns = result
            .unwrap_or_else(|error| panic!("attempt {attempt} after ALTER TABLE: {error:?}"))
            .columns
            .len();
        assert_eq!(columns, 3, "attempt {attempt}");
    }
}

#[tokio::test]
#[ignore = "requires docker"]
async fn application_errors_never_replay_nontransactional_effects() {
    let (_c, opts) = start_pg().await;
    let conn = connect(opts).await;
    conn.execute("CREATE SEQUENCE retry_probe").await.unwrap();
    conn.execute(
        "CREATE FUNCTION retry_probe_fn(code text, message text) RETURNS integer LANGUAGE plpgsql VOLATILE AS $$ \
         BEGIN PERFORM nextval('retry_probe'); \
         RAISE EXCEPTION USING ERRCODE = code, MESSAGE = message; END $$",
    )
    .await
    .unwrap();
    let mut attempts = 0;
    for (code, message) in [
        ("0A000", "unsupported operation"),
        ("0A000", "cached plan must not change result type"),
        ("XX000", "cache lookup failed for type 12345"),
    ] {
        let literal = format!("SELECT retry_probe_fn('{code}', '{message}')");
        let params = [Value::Text(code.into()), Value::Text(message.into())];
        let control = OperationControl::with_timeout(std::time::Duration::from_secs(30));
        let outcomes = [
            conn.query(&literal).await.map(|_| ()),
            conn.query_controlled(&literal, &control).await.map(|_| ()),
            conn.query_params("SELECT retry_probe_fn($1, $2)", &params)
                .await
                .map(|_| ()),
            conn.execute(&literal).await.map(|_| ()),
            conn.execute_params("SELECT retry_probe_fn($1, $2)", &params)
                .await
                .map(|_| ()),
            conn.execute_params_controlled("SELECT retry_probe_fn($1, $2)", &params, &control)
                .await
                .map(|_| ()),
        ];
        for outcome in outcomes {
            assert!(matches!(outcome, Err(DriverError::Query { sqlstate: Some(ref actual), .. }) if actual == code));
            attempts += 1;
        }
        let result = conn
            .query("SELECT last_value, is_called FROM retry_probe")
            .await
            .unwrap();
        assert_eq!(
            result.rows,
            vec![vec![Value::Int(attempts), Value::Bool(true)]],
            "{code}: {message}"
        );
    }
}
