#![allow(clippy::unwrap_used, clippy::expect_used, clippy::panic)]

use tablepro_core::Value;

use crate::{connect, start_pg};

#[tokio::test]
#[ignore = "requires docker"]
async fn a_column_type_change_does_not_poison_the_next_edit_of_the_same_statement() {
    let (_c, opts) = start_pg().await;
    let conn = connect(opts).await;
    conn.execute("CREATE TABLE pa (id int PRIMARY KEY, v int)")
        .await
        .unwrap();
    let sql = "INSERT INTO pa (id, v) VALUES ($1, $2)";
    let first = conn.execute_params(sql, &[Value::Int(1), Value::Int(5)]).await;
    assert!(first.is_ok(), "{first:?}");
    conn.execute("ALTER TABLE pa ALTER COLUMN v TYPE text USING v::text")
        .await
        .unwrap();
    let second = conn
        .execute_params(sql, &[Value::Int(2), Value::Text("abc".into())])
        .await;
    assert!(second.is_ok(), "insert after ALTER TYPE: {second:?}");
    let upd = "UPDATE pa SET v = $1 WHERE id = $2";
    let a = conn.execute_params(upd, &[Value::Int(9), Value::Int(1)]).await;
    assert!(a.is_ok(), "{a:?}");
    conn.execute("ALTER TABLE pa ALTER COLUMN v TYPE text USING v::text")
        .await
        .unwrap();
    let b = conn
        .execute_params(upd, &[Value::Text("x".into()), Value::Int(1)])
        .await;
    assert!(b.is_ok(), "update text after ALTER: {b:?}");
}
