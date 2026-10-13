#![allow(clippy::unwrap_used, clippy::expect_used, clippy::panic)]

use tablepro_core::Value;

use crate::{connect, start_pg};

const COLUMNS: [&str; 10] = ["n", "jb", "d", "u", "b", "num", "t", "ts", "ip", "j"];

#[tokio::test]
#[ignore = "requires docker"]
async fn a_null_parameter_takes_the_type_of_the_column_it_is_bound_to() {
    let (_c, opts) = start_pg().await;
    let conn = connect(opts).await;
    conn.execute(
        "CREATE TABLE nulls (id int PRIMARY KEY, n int, jb jsonb, d date, u uuid, b boolean, num numeric, \
         t text, ts timestamptz, ip inet, j json)",
    )
    .await
    .unwrap();
    conn.execute(
        "INSERT INTO nulls VALUES (1, 5, '{}', '2026-01-01', gen_random_uuid(), true, 1.5, 'a', now(), '10.0.0.1', '{}')",
    )
    .await
    .unwrap();

    for column in COLUMNS {
        let set_null = conn
            .execute_params(&format!("UPDATE nulls SET {column} = $1 WHERE id = 1"), &[Value::Null])
            .await;
        assert!(set_null.is_ok(), "setting {column} to NULL: {set_null:?}");
        if column == "j" {
            continue;
        }
        let compared = conn
            .execute_params(
                &format!("UPDATE nulls SET t = 'x' WHERE id = 1 AND {column} IS NOT DISTINCT FROM $1"),
                &[Value::Null],
            )
            .await;
        assert!(compared.is_ok(), "comparing {column} with NULL: {compared:?}");
    }

    let inserted = conn
        .execute_params(
            "INSERT INTO nulls (id, n, jb, d, u, ip) VALUES (2, $1, $2, $3, $4, $5)",
            &[Value::Null, Value::Null, Value::Null, Value::Null, Value::Null],
        )
        .await;
    assert!(inserted.is_ok(), "inserting NULLs: {inserted:?}");
}

#[tokio::test]
#[ignore = "requires docker"]
async fn a_null_in_an_ambiguous_placeholder_still_runs() {
    let (_c, opts) = start_pg().await;
    let conn = connect(opts).await;
    for sql in ["SELECT $1 IS NULL AS r", "SELECT $1 AS r"] {
        let result = conn.query_params(sql, &[Value::Null]).await;
        assert!(result.is_ok(), "{sql}: {result:?}");
    }
}
