#![allow(clippy::unwrap_used, clippy::expect_used, clippy::panic)]

use tablepro_core::sql_dialect::{build_insert_from_draft, build_keyed_delete, build_optimistic_keyed_update};
use tablepro_core::{Connection, Value};

use crate::{connect, start_pg};

const TEXT_COLUMNS: [(&str, &str, &str); 7] = [
    ("ip", "10.0.0.1", "10.0.0.2"),
    ("cd", "10.0.0.0/8", "192.168.0.0/16"),
    ("mac", "08:00:2b:01:02:03", "08:00:2b:01:02:04"),
    ("iv", "1 day", "2 days 03:00:00"),
    ("b3", "101", "010"),
    ("vb", "10101", "1"),
    ("c3", "ab ", "xy"),
];

async fn read_row(conn: &dyn Connection, sql: &str) -> Vec<Value> {
    conn.query(sql).await.unwrap().rows.remove(0)
}

#[tokio::test]
#[ignore = "requires docker"]
async fn native_text_decoded_types_survive_insert_edit_and_delete_through_the_builders() {
    let (_c, opts) = start_pg().await;
    let conn = connect(opts).await;
    conn.execute(
        "CREATE TABLE tw (id int PRIMARY KEY, ip inet, cd cidr, mac macaddr, iv interval, b3 bit(3), vb varbit(5), \
         c3 char(3), x xml, ts tsvector, j json)",
    )
    .await
    .unwrap();
    let columns = conn.fetch_columns(Some("public"), "tw").await.unwrap();

    let mut draft = vec![Value::Int(1)];
    for (name, first, _) in TEXT_COLUMNS {
        assert_eq!(columns[draft.len()].name, name);
        draft.push(Value::Text(first.into()));
    }
    draft.push(Value::Text("<a/>".into()));
    draft.push(Value::Text("'a' 'b'".into()));
    draft.push(Value::Json(serde_json::json!({"a": 1})));
    let (insert, params) = build_insert_from_draft("postgres", Some("public"), "tw", &columns, &draft).unwrap();
    let inserted = conn.execute_params(&insert, &params).await;
    assert!(inserted.is_ok(), "{insert}\n{inserted:?}");

    let mut edits = Vec::new();
    for (index, (name, _, second)) in TEXT_COLUMNS.iter().enumerate() {
        let old = read_row(conn.as_ref(), &format!("SELECT {name} FROM tw WHERE id = 1"))
            .await
            .remove(0);
        edits.push((index + 1, old, Value::Text((*second).into())));
    }
    let old_json = read_row(conn.as_ref(), "SELECT j FROM tw WHERE id = 1").await.remove(0);
    edits.push((columns.len() - 1, old_json, Value::Json(serde_json::json!({"a": 2}))));
    for edit in edits {
        let name = columns[edit.0].name.clone();
        let (update, params) =
            build_optimistic_keyed_update("postgres", Some("public"), "tw", &columns, &[edit], &[Value::Int(1)])
                .unwrap();
        let outcome = conn.execute_params(&update, &params).await;
        assert_eq!(
            outcome.as_ref().map(|result| result.rows_affected).ok(),
            Some(1),
            "{name}: {update}\n{outcome:?}"
        );
    }

    let (delete, params) = build_keyed_delete("postgres", Some("public"), "tw", &columns, &[Value::Int(1)]).unwrap();
    assert_eq!(conn.execute_params(&delete, &params).await.unwrap().rows_affected, 1);
}

#[tokio::test]
#[ignore = "requires docker"]
async fn a_padded_char_key_can_be_edited_and_deleted() {
    let (_c, opts) = start_pg().await;
    let conn = connect(opts).await;
    conn.execute("CREATE TABLE ck (code char(5) PRIMARY KEY, w int)")
        .await
        .unwrap();
    conn.execute("INSERT INTO ck VALUES ('ab', 1), ('cd', 2)")
        .await
        .unwrap();
    let columns = conn.fetch_columns(Some("public"), "ck").await.unwrap();
    let key = read_row(conn.as_ref(), "SELECT code FROM ck WHERE w = 1")
        .await
        .remove(0);

    let (update, params) = build_optimistic_keyed_update(
        "postgres",
        Some("public"),
        "ck",
        &columns,
        &[(1, Value::Int(1), Value::Int(5))],
        std::slice::from_ref(&key),
    )
    .unwrap();
    assert_eq!(
        conn.execute_params(&update, &params).await.unwrap().rows_affected,
        1,
        "{update}"
    );

    let (delete, params) = build_keyed_delete("postgres", Some("public"), "ck", &columns, &[key]).unwrap();
    assert_eq!(
        conn.execute_params(&delete, &params).await.unwrap().rows_affected,
        1,
        "{delete}"
    );
}
