#![allow(clippy::unwrap_used, clippy::expect_used, clippy::panic)]

use tablepro_core::Value;
use tablepro_core::sql_ddl::{DraftColumn, build_add_column};

use crate::{connect, start_pg};

#[tokio::test]
#[ignore = "requires docker"]
async fn a_new_serial_primary_key_column_is_added_with_its_key_to_a_table_with_rows() {
    let (_c, opts) = start_pg().await;
    let conn = connect(opts).await;
    conn.execute("CREATE TABLE keyless (a int)").await.unwrap();
    conn.execute("INSERT INTO keyless VALUES (10), (20)").await.unwrap();
    let column = DraftColumn {
        original: None,
        name: "k".into(),
        data_type: "integer".into(),
        nullable: false,
        primary_key: true,
        auto_increment: true,
        default_value: None,
        comment: None,
        collation: None,
    };

    for statement in build_add_column("postgres", None, "keyless", &column).unwrap() {
        conn.execute(&statement).await.unwrap();
    }

    let keys = conn
        .query(
            "SELECT a.attname::text FROM pg_index i JOIN pg_attribute a \
             ON a.attrelid = i.indrelid AND a.attnum = ANY (i.indkey) \
             WHERE i.indrelid = 'keyless'::regclass AND i.indisprimary",
        )
        .await
        .unwrap();
    assert_eq!(keys.rows, vec![vec![Value::Text("k".into())]]);
    let ids = conn.query("SELECT k FROM keyless ORDER BY k").await.unwrap();
    assert_eq!(ids.rows, vec![vec![Value::Int(1)], vec![Value::Int(2)]]);
}
